{
  lib,
  serverConfig,
  nodeConfig,
  ...
}:

let
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;
  isBootstrap = nodeConfig.bootstrap or false;
  onBootstrap = name: isBootstrap && (enabled name);
in
{
  imports =
    lib.optionals (onBootstrap "vaultwarden") [
      ./vaultwarden.nix
      ./vaultwarden-admin.nix
      ./vaultwarden-sync.nix
    ]
    ++ lib.optionals (onBootstrap "nextcloud") [
      ./nextcloud
    ]
    ++ lib.optionals (onBootstrap "immich") [
      ./immich.nix
    ]
    ++ lib.optionals (onBootstrap "syncthing") [
      ./syncthing.nix
      ./syncthing-folders.nix
    ];
}
