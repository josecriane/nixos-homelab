{ pkgs, k8s, ... }:

let
  ns = "media";
  releases = [
    "bookshelf"
    "kavita"
    "sonarr-es"
    "radarr-es"
  ];

  cleanup = pkgs.writeShellScript "media-removed-cleanup" ''
    ${k8s.libShSource}
    wait_for_k3s
    for release in ${toString releases}; do
      if $HELM status "$release" -n ${ns} >/dev/null 2>&1; then
        $HELM uninstall "$release" -n ${ns}
      fi
      $KUBECTL -n ${ns} delete ingressroute "$release" --ignore-not-found
      $KUBECTL -n ${ns} delete pvc "$release-config" --ignore-not-found
      $KUBECTL -n ${ns} delete secret "$release-credentials" "$release-api-key" --ignore-not-found
      rm -f "/var/lib/$release-setup-done"
    done
    rm -f /var/lib/kavita-config-setup-done
  '';
in
{
  systemd.services.media-removed-cleanup = {
    description = "Remove the Bookshelf, Kavita, Sonarr ES and Radarr ES releases";
    after = [ "k3s-apps.target" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = cleanup;
    };
  };
}
