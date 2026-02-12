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
  markerFile = "/var/lib/bazarr-setup-done";
in
{
  systemd.services.bazarr-setup = {
    description = "Setup Bazarr subtitle management";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
      "arr-stack-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "nfs-storage-setup.service"
      "arr-stack-setup.service"
    ];
    # TIER 4: Media
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "bazarr-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Bazarr"

        wait_for_k3s
        wait_for_resource "namespace" "default" "${ns}" 150
        wait_for_shared_data "${ns}"

        # PVC (config only, subtitles use shared-data)
        create_pvc "bazarr-config" "${ns}" "1Gi"

        # Deployment - uses shared-data with TRaSH Guides structure
        ${k8s.createLinuxServerDeployment {
          name = "bazarr";
          namespace = ns;
          image = "lscr.io/linuxserver/bazarr:1.5.5";
          port = 6767;
          configPVC = "bazarr-config";
          extraVolumeMounts = [
            "- name: data\n          mountPath: /data"
          ];
          extraVolumes = [
            "- name: data\n        persistentVolumeClaim:\n          claimName: shared-data"
          ];
        }}

        wait_for_pod "${ns}" "app=bazarr" 180

        # IngressRoute (ForwardAuth + local auth)
        create_ingress_route "bazarr" "${ns}" "$(hostname bazarr)" "bazarr" "6767" "authentik-forward-auth:traefik-system"

        print_success "Bazarr" \
          "URLs:" \
          "  URL: https://$(hostname bazarr)" \
          "" \
          "Connect with Sonarr/Radarr for subtitles"

        create_marker "${markerFile}"
      '';
    };
  };
}
