{
  config,
  lib,
  pkgs,
  serverConfig,
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
    ./systemd-targets.nix
    ./infrastructure/k3s.nix
    ./infrastructure/metallb.nix
    ./infrastructure/traefik.nix
    ./infrastructure/cert-manager.nix
    ./infrastructure/nfs-storage.nix
    ./infrastructure/cleanup.nix
    ./backup/restic.nix
  ]
  ++ lib.optionals (enabled "authentik") [
    ./auth/authentik.nix
    ./auth/sso.nix
  ]
  ++ lib.optionals ((enabled "authentik") && (serverConfig.authentik.ldap.enable or false)) [
    ./auth/ldap.nix
  ]
  ++ lib.optionals ((enabled "authentik") && anyNas) [
    ./auth/nas-apps.nix
  ]
  ++ lib.optionals (enabled "media") [
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
  ]
  ++ lib.optionals ((enabled "media") && anyNas) [
    ./media/nas-integration.nix
  ]
  ++ lib.optionals (enabled "vaultwarden") [
    ./cloud/vaultwarden.nix
    ./cloud/vaultwarden-admin.nix
    ./cloud/vaultwarden-sync.nix
  ]
  ++ lib.optionals (enabled "nextcloud") [ ./cloud/nextcloud.nix ]
  ++ lib.optionals (enabled "immich") [ ./cloud/immich.nix ]
  ++ lib.optionals (enabled "syncthing") [ ./cloud/syncthing.nix ]
  ++ lib.optionals (enabled "monitoring") [
    ./monitoring/grafana-prometheus.nix
    ./monitoring/loki.nix
    ./monitoring/uptime-kuma.nix
  ]
  ++ lib.optionals (enabled "dashboard") [
    ./dashboard/homarr.nix
  ]
  ++ lib.optionals (enabled "kiwix") [
    ./knowledge/kiwix.nix
  ];
}
