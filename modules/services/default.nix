{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./tailscale.nix
  ];
}
