# Bookshelf (PennyDreadful) - arr-style ebook management
# Declared via bjw-s/app-template Helm library chart. Values live next to
# this module as plain YAML (values.yaml); tokens like __TIMEZONE__, __PUID__,
# __PGID__ are substituted from config at build time.
{
  k8s,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let

  release = k8s.createHelmRelease {
    name = "bookshelf";
    namespace = "media";
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "bookshelf";
    ingress = {
      host = "books";
      service = "bookshelf";
      port = 8787;
    };
    middlewares = k8s.forwardAuthMiddleware;
  };
in
lib.recursiveUpdate release {
  dashboard.items.bookshelf = {
    group = "downloads";
    title = "Bookshelf";
    icon = "fas fa-book";
    subtitle = "Ebooks";
    url = "https://${k8s.hostname "books"}";
    sort = 90;
  };
  systemd.services.bookshelf-setup = {
    after = (release.systemd.services.bookshelf-setup.after or [ ]) ++ [
      "arr-secrets-setup.service"
      "nfs-storage-setup.service"
    ];
    wants = [
      "arr-secrets-setup.service"
      "nfs-storage-setup.service"
    ];
  };
}
