{
  config,
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  ...
}:

let
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;
  nas = serverConfig.nas or { };
  anyNas =
    (builtins.length (builtins.attrNames (lib.filterAttrs (_: c: c.enabled or false) nas))) > 0;
  isBootstrap = nodeConfig.bootstrap or false;
in
{
  # Upstream's modules/kubernetes/default.nix (loaded by nixos-k8s.lib.mkCluster)
  # already provides K3s, MetalLB, Traefik, cert-manager, NFS mounts, cleanup,
  # nfs-storage and systemd-targets. Homelab only adds its own services on top.
  # All cluster-service modules are bootstrap-only: agents just run kubelet.
  imports =
    lib.optionals isBootstrap [
      # Homelab-specific overlay: configures upstream nfs-storage + adds cloud PVs.
      ./infrastructure/nfs-storage.nix
      ./infrastructure/nfs-storage-cloud.nix
      ./infrastructure/cleanup-services.nix

      ./backup/restic.nix

      # Auth
      ./auth/authentik.nix
      ./auth/sso.nix

      # Media
      ./media/arr-stack.nix
      ./media/arr-secrets.nix
      ./media/arr-credentials.nix
      ./media/arr-download-clients.nix
      ./media/arr-prowlarr-sync.nix
      ./media/arr-root-folders.nix
      ./media/arr-naming.nix
      ./media/lidarr-config.nix
      ./media/bazarr-config.nix
      ./media/jellyfin.nix
      ./media/jellyfin-integration.nix
      ./media/jellyseerr.nix
      ./media/bazarr.nix
      ./media/lidarr.nix
      ./media/bookshelf.nix
      ./media/flaresolverr.nix
      ./media/recyclarr.nix
      ./media/kavita.nix

      # Cloud
      ./cloud/vaultwarden.nix
      ./cloud/vaultwarden-admin.nix
      ./cloud/vaultwarden-sync.nix
      ./cloud/nextcloud.nix
      ./cloud/immich.nix
      ./cloud/syncthing.nix

      # Monitoring
      ./monitoring/grafana-prometheus.nix
      ./monitoring/loki.nix

      # Dashboard
      ./dashboard/homer.nix
      ./dashboard/service-manager.nix

      # Knowledge
      ./knowledge/kiwix.nix
      ./knowledge/openstreetmap.nix
    ]
    # Hardware/config-dependent modules stay conditional
    ++
      lib.optionals
        (isBootstrap && (enabled "authentik") && (serverConfig.authentik.ldap.enable or false))
        [
          ./auth/ldap.nix
        ]
    ++
      lib.optionals
        (isBootstrap && (enabled "authentik") && (serverConfig.authentik.bootstrapUsers or { }) != { })
        [
          ./auth/authentik-users.nix
        ]
    ++ lib.optionals (isBootstrap && (enabled "authentik") && anyNas) [
      ./auth/nas-apps.nix
    ]
    ++ lib.optionals (isBootstrap && (enabled "media") && anyNas) [
      ./media/nas-integration.nix
    ];
}
