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
in
{
  # homer: bootstrap-only, gated by `services.dashboard`.
  # service-manager.nix is homelab glue that sets `k8s.apps.serviceManager`
  # (option defined by the upstream service-manager module). It must only
  # load when the upstream module is also active.
  imports =
    lib.optionals (isBootstrap && (enabled "dashboard")) [
      ./homer
    ]
    ++ lib.optionals (enabled "service-manager") [
      ./service-manager.nix
    ];
}
