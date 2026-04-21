{
  lib,
  nodeConfig,
  ...
}:

let
  isBootstrap = nodeConfig.bootstrap or false;
in
{
  imports = lib.optionals isBootstrap [
    ./restic.nix
  ];
}
