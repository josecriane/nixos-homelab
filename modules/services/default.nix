{
  lib,
  nodeConfig,
  ...
}:

{
  # Tailscale (subnet router) and Omada-controller firewall rules only make
  # sense on the bootstrap node. Agents just run kubelet + k3s agent.
  imports = lib.optionals (nodeConfig.bootstrap or false) [
    ./tailscale.nix
    ./omada-ports.nix
  ];
}
