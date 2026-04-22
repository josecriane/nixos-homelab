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
  imports = lib.optionals (isBootstrap && (enabled "monitoring")) [
    ./grafana-oidc.nix
  ];
}
