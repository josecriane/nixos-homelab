{
  config,
  lib,
  pkgs,
  ...
}:

{
  # SSH Server
  services.openssh = {
    enable = true;
    ports = [ 22 ];

    settings = {
      # Key-only authentication
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;

      # Additional security
      X11Forwarding = false;
      PermitEmptyPasswords = false;
      MaxAuthTries = 3;

      # Keep connection alive
      ClientAliveInterval = 60;
      ClientAliveCountMax = 3;
    };
  };

  # Open SSH port in firewall
  networking.firewall.allowedTCPPorts = [ 22 ];
}
