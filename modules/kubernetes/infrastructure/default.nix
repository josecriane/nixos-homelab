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
    ./nfs-storage-secondary.nix
    ./cleanup-services.nix
  ];
}
