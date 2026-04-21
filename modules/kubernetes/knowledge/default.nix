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
    lib.optionals (onBootstrap "kiwix") [
      ./kiwix
    ]
    ++ lib.optionals (onBootstrap "openstreetmap") [
      ./openstreetmap
    ];
}
