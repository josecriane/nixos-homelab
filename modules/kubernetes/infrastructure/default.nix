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
    ./nfs-storage.nix
    ./nfs-storage-cloud.nix
    ./cleanup-services.nix
  ];
}
