{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

{
  imports = [
    ./nix.nix
    ./users.nix
    ./ssh.nix
    ./security.nix
    ./kdump.nix
  ];

  # Timezone and locale
  time.timeZone = serverConfig.timezone;
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME = "en_US.UTF-8";
  };

  # Base system packages
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    btop
    tmux
    jq
    yq-go
    tree
    ncdu
    duf
    ripgrep
    fd
    smartmontools
  ];

  # Firmware updates
  services.fwupd.enable = true;

  # Disable graphical interface
  services.xserver.enable = false;

  # Enable documentation
  documentation.enable = true;
  documentation.man.enable = true;
}
