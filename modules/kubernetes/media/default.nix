{
  lib,
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
  mediaOn = isBootstrap && (enabled "media");
in
{
  imports =
    lib.optionals mediaOn [
      ./arr-stack
      ./arr-secrets.nix
      ./arr-credentials.nix
      ./arr-download-clients.nix
      ./arr-prowlarr-sync.nix
      ./arr-root-folders.nix
      ./arr-naming.nix
      ./lidarr-config.nix
      ./bazarr-config.nix
      ./jellyfin
      ./jellyfin-integration.nix
      ./jellyseerr
      ./bazarr
      ./lidarr
      ./bookshelf
      ./flaresolverr
      ./recyclarr.nix
      ./kavita
    ]
    ++ lib.optionals (mediaOn && anyNas) [
      ./nas-integration.nix
    ];
}
