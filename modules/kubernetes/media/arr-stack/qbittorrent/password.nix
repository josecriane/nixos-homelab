# qBittorrent post-install password configuration.
# qBittorrent 5.x generates a random temporary password on first start and
# prints it in the logs. This service reads that temp password, sets a stable
# one from a K8s secret (generating it if missing), and configures the save
# path under /data/torrents.
{
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/qbittorrent-password-setup-done";
in
{
  systemd.services.qbittorrent-password-setup = {
    description = "Configure qBittorrent WebUI password";
    after = [
      "k3s-apps.target"
      "qbittorrent-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [ "qbittorrent-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "qbittorrent-password-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "qBittorrent password"

        wait_for_k3s
        wait_for_deployment "${ns}" "qbittorrent" 180

        QBIT_PASSWORD=$(get_secret_value "${ns}" "qbittorrent-credentials" "PASSWORD")
        if [ -n "$QBIT_PASSWORD" ]; then
          echo "qBittorrent password already configured, skipping"
          create_marker "${markerFile}"
          exit 0
        fi

        QBIT_PASSWORD=$(generate_password 16)
        echo "Configuring qBittorrent password..."

        for i in $(seq 1 30); do
          if $KUBECTL exec -n ${ns} deploy/qbittorrent -- curl -sf http://localhost:8080/api/v2/app/version 2>/dev/null; then
            break
          fi
          sleep 3
        done

        TEMP_PASS=$($KUBECTL logs -n ${ns} deploy/qbittorrent 2>/dev/null | grep -oP 'temporary password is: \K\S+' | tail -1)
        if [ -z "$TEMP_PASS" ]; then
          TEMP_PASS="adminadmin"
        fi

        QBIT_COOKIE=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
          curl -s -c - -d "username=admin&password=$TEMP_PASS" http://localhost:8080/api/v2/auth/login 2>/dev/null | grep SID | ${pkgs.gawk}/bin/awk '{print $NF}')
        if [ -n "$QBIT_COOKIE" ]; then
          $KUBECTL exec -n ${ns} deploy/qbittorrent -- \
            curl -s -b "SID=$QBIT_COOKIE" \
            -d "json={\"web_ui_password\":\"$QBIT_PASSWORD\",\"save_path\":\"/data/torrents\",\"temp_path\":\"/data/torrents/incomplete\",\"temp_path_enabled\":true}" \
            http://localhost:8080/api/v2/app/setPreferences 2>/dev/null
          echo "qBittorrent password and save path configured"
        else
          echo "WARNING: Could not authenticate to qBittorrent, password not set"
          exit 1
        fi

        store_credentials "${ns}" "qbittorrent-credentials" \
          "USER=admin" "PASSWORD=$QBIT_PASSWORD" "URL=https://$(hostname qbit)"

        print_success "qBittorrent password" \
          "Admin: admin" \
          "URL: https://$(hostname qbit)"

        create_marker "${markerFile}"
      '';
    };
  };
}
