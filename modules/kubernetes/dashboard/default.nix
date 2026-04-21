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
  # switchboard.nix is homelab glue that sets `k8s.apps.switchboard`
  # (option defined by the upstream switchboard module). It must only
  # load when the upstream module is also active.
  imports =
    lib.optionals (isBootstrap && (enabled "dashboard")) [
      ./homer
    ]
    ++ lib.optionals (enabled "switchboard") [
      ./switchboard.nix
    ];
}
