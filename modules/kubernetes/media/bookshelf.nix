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
  markerFile = "/var/lib/bookshelf-setup-done";
in
{
  systemd.services.bookshelf-setup = {
    description = "Setup Bookshelf for ebook management";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
      "arr-secrets-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "nfs-storage-setup.service"
      "arr-secrets-setup.service"
    ];
    # TIER 4: Media
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "bookshelf-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Bookshelf"

        wait_for_k3s
        wait_for_resource "namespace" "default" "${ns}" 150
        wait_for_shared_data "${ns}"

        # PVCs (config only, books uses shared-data)
        create_pvc "bookshelf-config" "${ns}" "1Gi"

        # Deployment - uses shared-data with TRaSH Guides structure
        ${k8s.createLinuxServerDeployment {
          name = "bookshelf";
          namespace = ns;
          image = "ghcr.io/pennydreadful/bookshelf:hardcover";
          port = 8787;
          configPVC = "bookshelf-config";
          apiKeySecret = "bookshelf-api-key";
          extraVolumeMounts = [
            "- name: data\n          mountPath: /data"
          ];
          extraVolumes = [
            "- name: data\n        persistentVolumeClaim:\n          claimName: shared-data"
          ];
        }}

        wait_for_pod "${ns}" "app=bookshelf" 180

        # IngressRoute (ForwardAuth + local auth)
        create_ingress_route "bookshelf" "${ns}" "$(hostname books)" "bookshelf" "8787" "authentik-forward-auth:traefik-system"

        print_success "Bookshelf" \
          "URLs:" \
          "  URL: https://$(hostname books)" \
          "" \
          "Connect with Prowlarr and qBittorrent"

        create_marker "${markerFile}"
      '';
    };
  };
}
