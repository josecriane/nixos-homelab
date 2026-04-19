{ ... }:

{
  # Omada Controller runs outside Kubernetes on the host (java/docker-compose,
  # not managed by this flake). These rules let APs discover and adopt into it.
  networking.firewall = {
    allowedTCPPorts = [
      8088 # HTTP portal
      8043 # HTTPS portal
      8843 # Portal HTTPS (captive portal)
      29811 # Manager v1
      29812 # Adopt v1
      29813 # Upgrade v1
      29814 # Manager v2
      29815 # Transfer v2
      29816 # Extra
      29817 # Extra
    ];

    allowedUDPPorts = [
      29810 # Controller discovery
      27001 # App discovery
    ];
  };
}
