{
  config,
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;
  nas = serverConfig.nas or { };
  anyNas =
    (builtins.length (builtins.attrNames (lib.filterAttrs (_: c: c.enabled or false) nas))) > 0;
in
{
  imports = [
    "${nixos-k8s}/modules/kubernetes/systemd-targets.nix"
    "${nixos-k8s}/modules/kubernetes/infrastructure/k3s.nix"
    "${nixos-k8s}/modules/kubernetes/infrastructure/metallb.nix"
    "${nixos-k8s}/modules/kubernetes/infrastructure/traefik.nix"
    "${nixos-k8s}/modules/kubernetes/infrastructure/traefik-dashboard.nix"
    "${nixos-k8s}/modules/kubernetes/infrastructure/cert-manager.nix"
    "${nixos-k8s}/modules/kubernetes/infrastructure/cleanup.nix"
    "${nixos-k8s}/modules/kubernetes/infrastructure/nfs-mounts.nix"
    ./infrastructure/nfs-storage.nix
    ./infrastructure/cleanup.nix
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
  ++ lib.optionals ((enabled "authentik") && (serverConfig.authentik.ldap.enable or false)) [
    ./auth/ldap.nix
  ]
  ++ lib.optionals ((enabled "authentik") && anyNas) [
    ./auth/nas-apps.nix
  ]
  ++ lib.optionals ((enabled "media") && anyNas) [
    ./media/nas-integration.nix
  ];
}
