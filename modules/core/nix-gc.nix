{ lib, ... }:

{
  nix.gc = {
    automatic = lib.mkDefault true;
    dates = lib.mkDefault "weekly";
    options = lib.mkForce "--delete-older-than 14d";
    persistent = lib.mkDefault true;
  };

  nix.optimise = {
    automatic = true;
    dates = [ "03:45" ];
  };

  nix.settings = {
    auto-optimise-store = true;
    min-free = toString (5 * 1024 * 1024 * 1024);
    max-free = toString (20 * 1024 * 1024 * 1024);
  };

  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 20;
}
