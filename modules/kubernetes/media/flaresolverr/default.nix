# FlareSolverr - Cloudflare bypass proxy for Prowlarr
# Declared via bjw-s/app-template Helm library chart. Values live next to
# this module as plain YAML (values.yaml); tokens like __TIMEZONE__ are
# substituted from config at build time.
{
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  values = pkgs.writeText "flaresolverr-values.yaml" (
    builtins.replaceStrings
      [ "__TIMEZONE__" ]
      [ serverConfig.timezone ]
      (builtins.readFile ./values.yaml)
  );
in
k8s.createHelmRelease {
  name = "flaresolverr";
  namespace = "media";
  tier = "apps";
  chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
  version = "4.6.1";
  valuesFile = values;
  waitFor = "flaresolverr";
}
