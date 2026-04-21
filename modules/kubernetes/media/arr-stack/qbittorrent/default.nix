# qBittorrent - BitTorrent client
# Declared via bjw-s/app-template Helm library chart. Two services:
# ClusterIP for the WebUI (Authentik ForwardAuth) and LoadBalancer for
# BitTorrent peer traffic on port 6881 (TCP/UDP).
# Post-install password configuration runs in a separate systemd service
# (see ./password.nix) to keep the Helm release reconciliation idempotent.
{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };

  release = k8s.createHelmRelease {
    name = "qbittorrent";
    namespace = "media";
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "qbittorrent";
    ingress = {
      host = "qbit";
      service = "qbittorrent";
      port = 8080;
    };
    middlewares = k8s.forwardAuthMiddleware;
  };
in
lib.recursiveUpdate release {
  systemd.services.qbittorrent-setup = {
    after = (release.systemd.services.qbittorrent-setup.after or [ ]) ++ [
      "nfs-storage-setup.service"
    ];
    wants = [
      "nfs-storage-setup.service"
    ];
  };
}
