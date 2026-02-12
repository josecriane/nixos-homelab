{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  inputs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  # Hostname
  networking.hostName = serverConfig.serverName;

  # Local DNS cache (reduces load on Pi-hole)
  services.dnsmasq = {
    enable = true;
    settings = {
      cache-size = 1000;
      server = serverConfig.nameservers ++ [
        "1.1.1.1"
        "8.8.8.8"
      ]; # Fallbacks
      listen-address = "127.0.0.1";
      bind-interfaces = true;
      no-resolv = true;
    };
  };

  # Network
  networking = {
    useDHCP = false;
    useNetworkd = true;
    nameservers = [ "127.0.0.1" ] ++ serverConfig.nameservers; # dnsmasq first

    # Prefer IPv4 over IPv6 for outgoing connections
    # Fixes issues with Docker/Helm when CDNs return IPv6 addresses
    getaddrinfo.precedence = {
      "::ffff:0:0/96" = 100; # IPv4 mapped addresses (highest priority)
      "::1/128" = 50;
      "::/0" = 40;
    };

    # WiFi or Ethernet depending on configuration
    wireless = lib.mkIf serverConfig.useWifi {
      enable = true;
      networks."${serverConfig.wifiSSID}" = {
        pskRaw = "ext:wifi_psk";
      };
    };
  };

  # Static IP - matches any ethernet interface automatically
  systemd.network = {
    enable = true;
    wait-online.enable = false; # Services have their own network checks (k3s-network-check, etc.)
    networks."10-lan" =
      if serverConfig.useWifi then
        {
          matchConfig.Name = "wlan0";
          address = [ "${serverConfig.serverIP}/24" ];
          routes = [ { Gateway = serverConfig.gateway; } ];
          dns = serverConfig.nameservers;
          linkConfig.RequiredForOnline = "routable"; # Require routable state
        }
      else
        {
          # Match physical ethernet only (eno*, enp*, ens*), NOT veth* from CNI
          matchConfig.Name = "en*";
          address = [ "${serverConfig.serverIP}/24" ];
          routes = [ { Gateway = serverConfig.gateway; } ];
          dns = serverConfig.nameservers;
          linkConfig.RequiredForOnline = "routable";
          networkConfig = {
            # Disable IPv6 to prevent delays
            LinkLocalAddressing = "ipv4";
            IPv6AcceptRA = false;
          };
        };
  };

  # Secret for WiFi password (if using WiFi)
  age.secrets.wifi-password = lib.mkIf serverConfig.useWifi {
    file = "${secretsPath}/wifi-password.age";
    path = "/run/secrets/wifi_psk";
  };

  # System state version
  system.stateVersion = "25.11";
}
