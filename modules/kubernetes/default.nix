{
  # Upstream's modules/kubernetes/default.nix (loaded by nixos-k8s.lib.mkCluster)
  # already provides K3s, MetalLB, Traefik, cert-manager, NFS mounts, cleanup,
  # nfs-storage and systemd-targets. Homelab only adds its own services on top.
  # Each category's default.nix gates its modules on nodeConfig.bootstrap and
  # serverConfig.services toggles.
  imports = [
    ./auth
    ./backup
    ./cloud
    ./dashboard
    ./infrastructure
    ./knowledge
    ./media
    ./monitoring
  ];
}
