{
  # Upstream's modules/kubernetes/default.nix (loaded by nixos-k8s.lib.mkCluster)
  # already provides K3s, MetalLB, Traefik, cert-manager, NFS mounts, cleanup,
  # nfs-storage and systemd-targets. Homelab only adds its own services on top.
  imports = [
    ./auth
    ./backup
    ./cloud
    ./dashboard
    ./documents
    ./infrastructure
    ./knowledge
    ./media
    ./monitoring
  ];
}
