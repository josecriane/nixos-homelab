# Lidarr - music management (arr-stack)
# Declared via bjw-s/app-template Helm library chart. Init container
# pre-seeds /config/config.xml with the stable API key from lidarr-api-key
# secret (created by arr-secrets-setup.service). Ingress uses Authentik
# ForwardAuth middleware + Lidarr's own local auth.
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
    name = "lidarr";
    namespace = "media";
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "lidarr";
    ingress = {
      host = "lidarr";
      service = "lidarr";
      port = 8686;
    };
    middlewares = k8s.forwardAuthMiddleware;
  };
in
lib.recursiveUpdate release {
  systemd.services.lidarr-setup = {
    after = (release.systemd.services.lidarr-setup.after or [ ]) ++ [
      "arr-secrets-setup.service"
      "arr-stack-setup.service"
      "nfs-storage-setup.service"
    ];
    wants = [
      "arr-secrets-setup.service"
      "arr-stack-setup.service"
      "nfs-storage-setup.service"
    ];
  };
}
