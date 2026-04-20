{
  lib,
  nodeConfig,
  ...
}:

{
  # Tailscale (subnet router) only runs on the bootstrap node. Agents just
  # run kubelet + k3s agent.
  imports = lib.optionals (nodeConfig.bootstrap or false) [
    ./tailscale.nix
  ];
}
