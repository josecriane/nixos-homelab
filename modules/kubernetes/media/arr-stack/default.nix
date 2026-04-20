# arr-stack umbrella: aggregates prowlarr + sonarr(+es) + radarr(+es) +
# qbittorrent as 6 independent Helm releases. An umbrella `arr-stack-setup`
# oneshot preserves the composite dependency name that downstream services
# (bazarr, lidarr, recyclarr, etc.) use to order themselves after the stack.
#
# Firewall rules for BitTorrent peer traffic (MetalLB layer2 ARPs the host
# interface, so host packets must pass the firewall before kube-proxy DNATs
# them to qbittorrent pods) live here too.
{ pkgs, ... }:

{
  imports = [
    ./prowlarr.nix
    ./sonarr.nix
    ./sonarr-es.nix
    ./radarr.nix
    ./radarr-es.nix
    ./qbittorrent
    ./qbittorrent/password.nix
  ];

  systemd.services.arr-stack-setup = {
    description = "arr-stack umbrella (Prowlarr, Sonarr, Radarr, qBittorrent)";
    after = [
      "prowlarr-setup.service"
      "sonarr-setup.service"
      "sonarr-es-setup.service"
      "radarr-setup.service"
      "radarr-es-setup.service"
      "qbittorrent-setup.service"
    ];
    wants = [
      "prowlarr-setup.service"
      "sonarr-setup.service"
      "sonarr-es-setup.service"
      "radarr-setup.service"
      "radarr-es-setup.service"
      "qbittorrent-setup.service"
    ];
    wantedBy = [ "k3s-apps.target" ];
    before = [ "k3s-apps.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
  };

  networking.firewall = {
    allowedTCPPorts = [ 6881 ];
    allowedUDPPorts = [ 6881 ];
  };
}
