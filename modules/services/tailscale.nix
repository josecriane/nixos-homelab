{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  ipParts = lib.splitString "." serverConfig.serverIP;
  lanSubnet = "${builtins.elemAt ipParts 0}.${builtins.elemAt ipParts 1}.${builtins.elemAt ipParts 2}.0/24";
in
{
  # Secret for Tailscale auth key
  age.secrets.tailscale-auth-key = {
    file = "${secretsPath}/tailscale-auth-key.age";
  };

  # Tailscale VPN
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server"; # Allow acting as subnet router
    authKeyFile = config.age.secrets.tailscale-auth-key.path;
    extraUpFlags = [
      "--advertise-routes=${lanSubnet}"
      "--accept-dns=true"
    ];
  };

  # Open Tailscale port
  networking.firewall = {
    allowedUDPPorts = [ 41641 ];
    trustedInterfaces = [ "tailscale0" ];
  };

  # Tailscale package available system-wide
  environment.systemPackages = [ pkgs.tailscale ];
}
