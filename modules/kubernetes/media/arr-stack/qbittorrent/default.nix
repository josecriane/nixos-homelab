# qBittorrent - BitTorrent client
# Declared via bjw-s/app-template Helm library chart. Two services:
# ClusterIP for the WebUI (Authentik ForwardAuth) and LoadBalancer for
# BitTorrent peer traffic on port 6881 (TCP/UDP).
# Post-install password configuration runs in a separate systemd service
# (see ./password.nix) to keep the Helm release reconciliation idempotent.
{
  config,
  k8s,
  lib,
  pkgs,
  ...
}:

let
  paths = import ../../../media-paths.nix {
    inherit lib k8s;
    cluster = config.cluster;
  };

  release = {
    after = [
      "nfs-storage-setup.service"
    ];
    namespace = "media";
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    values = lib.optionalAttrs (paths.secondary != [ ]) { persistence = paths.persistence; };
    waitFor = "qbittorrent";
    ingresses = [
      {
        host = "qbit";
        service = "qbittorrent";
        port = 8080;
      }
    ];
    middlewares = k8s.forwardAuthMiddleware;
  };
in
lib.mkIf (config.cluster.isBootstrap && config.cluster.services.media) {
  k8s.helmReleases.qbittorrent = release;
  dashboard.items.qbittorrent = {
    group = "downloads";
    title = "qBittorrent";
    icon = "sh-qbittorrent";
    subtitle = "Downloads";
    url = "https://${k8s.hostname "qbit"}";
    workload = {
      namespace = "media";
      name = "qbittorrent";
    };
    widget = {
      type = "qbittorrent";
      url = "http://qbittorrent.media.svc.cluster.local:8080";
      secrets = {
        username = {
          namespace = "media";
          secret = "qbittorrent-credentials";
          key = "USER";
        };
        password = {
          namespace = "media";
          secret = "qbittorrent-credentials";
          key = "PASSWORD";
        };
      };
    };
    sort = 80;
  };
}
