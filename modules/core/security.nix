{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Firewall
  networking.firewall = {
    enable = true;
    allowPing = true;

    # Default open ports (SSH is already in ssh.nix)
    allowedTCPPorts = [
      80 # HTTP  - Traefik
      443 # HTTPS - Traefik
    ];

    allowedUDPPorts = [
      # 51820 # WireGuard - Si lo usas directamente
    ];
  };

  # Fail2ban for brute force protection
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      maxtime = "48h";
      factor = "4";
    };

    jails = {
      sshd = {
        settings = {
          enabled = true;
          port = "ssh";
          filter = "sshd";
          maxretry = 3;
        };
      };
    };
  };

  # Security limits
  security.protectKernelImage = true;
}
