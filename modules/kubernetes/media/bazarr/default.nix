# Bazarr - subtitle management (arr-stack)
# Declared via bjw-s/app-template Helm library chart. No init container
# (Bazarr auto-provisions its own DB and config). Ingress uses Authentik
# ForwardAuth middleware + Bazarr's own local auth.
{
  config,
  k8s,
  lib,
  pkgs,
  ...
}:

let

  release = {
    after = [
      "arr-stack-setup.service"
      "nfs-storage-setup.service"
    ];
    namespace = "media";
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "bazarr";
    ingresses = [
      {
        host = "bazarr";
        service = "bazarr";
        port = 6767;
      }
    ];
    middlewares = k8s.forwardAuthMiddleware;
  };
in
lib.mkIf (config.cluster.isBootstrap && config.cluster.services.media) {
  k8s.helmReleases.bazarr = release;
  dashboard.items.bazarr = {
    group = "downloads";
    title = "Bazarr";
    icon = "sh-bazarr";
    subtitle = "Subtitles";
    url = "https://${k8s.hostname "bazarr"}";
    workload = {
      namespace = "media";
      name = "bazarr";
    };
    widget = {
      type = "bazarr";
      url = "http://bazarr.media.svc.cluster.local:6767";
      secrets.key = {
        namespace = "media";
        secret = "bazarr-credentials";
        key = "API_KEY";
      };
    };
    sort = 60;
  };
}
