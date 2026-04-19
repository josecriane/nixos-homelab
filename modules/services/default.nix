{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./tailscale.nix
    ./omada-ports.nix
  ];
}
