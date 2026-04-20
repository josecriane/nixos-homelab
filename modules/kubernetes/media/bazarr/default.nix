# Bazarr - subtitle management (arr-stack)
# Declared via bjw-s/app-template Helm library chart. No init container
# (Bazarr auto-provisions its own DB and config). Ingress uses Authentik
# ForwardAuth middleware + Bazarr's own local auth.
{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  puid = toString (serverConfig.puid or 1000);
  pgid = toString (serverConfig.pgid or 1000);
  values = pkgs.writeText "bazarr-values.yaml" (
    builtins.replaceStrings [ "__TIMEZONE__" "__PUID__" "__PGID__" ] [ serverConfig.timezone puid pgid ]
      (builtins.readFile ./values.yaml)
  );

  release = k8s.createHelmRelease {
    name = "bazarr";
    namespace = "media";
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = values;
    waitFor = "bazarr";
    ingress = {
      host = "bazarr";
      service = "bazarr";
      port = 6767;
    };
    middlewares = k8s.forwardAuthMiddleware;
  };
in
lib.recursiveUpdate release {
  systemd.services.bazarr-setup = {
    after = (release.systemd.services.bazarr-setup.after or [ ]) ++ [
      "arr-stack-setup.service"
      "nfs-storage-setup.service"
    ];
    wants = [
      "arr-stack-setup.service"
      "nfs-storage-setup.service"
    ];
  };
}
