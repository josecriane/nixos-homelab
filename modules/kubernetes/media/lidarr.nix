{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/lidarr-setup-done";
in
{
  systemd.services.lidarr-setup = {
    description = "Setup Lidarr music management";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
      "arr-stack-setup.service"
      "arr-secrets-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "nfs-storage-setup.service"
      "arr-stack-setup.service"
      "arr-secrets-setup.service"
    ];
    # TIER 4: Media
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "lidarr-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Lidarr"

        wait_for_k3s
        wait_for_resource "namespace" "default" "${ns}" 150
        wait_for_shared_data "${ns}"

        # PVCs (config only, music uses shared-data)
        create_pvc "lidarr-config" "${ns}" "1Gi"

        # Deployment - uses shared-data with TRaSH Guides structure
        ${k8s.createLinuxServerDeployment {
          name = "lidarr";
          namespace = ns;
          image = "lscr.io/linuxserver/lidarr:3.1.0";
          port = 8686;
          configPVC = "lidarr-config";
          apiKeySecret = "lidarr-api-key";
          extraVolumeMounts = [
            "- name: data\n          mountPath: /data"
          ];
          extraVolumes = [
            "- name: data\n        persistentVolumeClaim:\n          claimName: shared-data"
          ];
        }}

        wait_for_pod "${ns}" "app=lidarr" 180

        # IngressRoute (ForwardAuth + local auth)
        create_ingress_route "lidarr" "${ns}" "$(hostname lidarr)" "lidarr" "8686" "authentik-forward-auth:traefik-system"

        print_success "Lidarr" \
          "URLs:" \
          "  URL: https://$(hostname lidarr)" \
          "" \
          "Connect with Prowlarr and qBittorrent"

        create_marker "${markerFile}"
      '';
    };
  };
}
