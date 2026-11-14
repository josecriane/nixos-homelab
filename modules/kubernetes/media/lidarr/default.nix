# Lidarr - music management (arr-stack)
# Declared via bjw-s/app-template Helm library chart. Init container
# pre-seeds /config/config.xml with the stable API key from lidarr-api-key
# secret (created by arr-secrets-setup.service). Ingress uses Authentik
# ForwardAuth middleware + Lidarr's own local auth.
{
  config,
  k8s,
  lib,
  pkgs,
  ...
}:

let
  paths = import ../../media-paths.nix {
    inherit lib k8s;
    cluster = config.cluster;
  };

  release = {
    after = [
      "arr-secrets-setup.service"
      "arr-stack-setup.service"
      "nfs-storage-setup.service"
    ];
    namespace = "media";
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    values = lib.optionalAttrs (paths.secondary != [ ]) { persistence = paths.persistence; };
    waitFor = "lidarr";
    ingresses = [
      {
        host = "lidarr";
        service = "lidarr";
        port = 8686;
      }
    ];
    middlewares = k8s.forwardAuthMiddleware;
  };
in
lib.mkIf (config.cluster.isBootstrap && config.cluster.services.media) {
  k8s.helmReleases.lidarr = release;
  dashboard.items.lidarr = {
    group = "downloads";
    title = "Lidarr";
    icon = "sh-lidarr";
    subtitle = "Music";
    url = "https://${k8s.hostname "lidarr"}";
    workload = {
      namespace = "media";
      name = "lidarr";
    };
    widget = {
      type = "lidarr";
      url = "http://lidarr.media.svc.cluster.local:8686";
      secrets.key = {
        namespace = "media";
        secret = "lidarr-api-key";
        key = "api-key";
      };
    };
    sort = 50;
  };
}
