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
      8088 # Omada Controller HTTP
      8043 # Omada Controller HTTPS
      8843 # Omada Controller portal HTTPS
      29811 # Omada Controller manager v1
      29812 # Omada Controller adopt v1
      29813 # Omada Controller upgrade v1
      29814 # Omada Controller manager v2
      29815 # Omada Controller transfer v2
      29816 # Omada Controller
      29817 # Omada Controller
    ];

    allowedUDPPorts = [
      29810 # Omada Controller discovery
      27001 # Omada Controller app discovery
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
