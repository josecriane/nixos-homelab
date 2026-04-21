# FlareSolverr - Cloudflare bypass proxy for Prowlarr
# Declared via bjw-s/app-template Helm library chart. Values live next to
# this module as plain YAML (values.yaml). Common tokens (__TIMEZONE__,
# __PUID__, __PGID__) are auto-substituted by createHelmRelease.
{
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
in
k8s.createHelmRelease {
  name = "flaresolverr";
  namespace = "media";
  tier = "apps";
  chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
  version = "4.6.1";
  valuesFile = ./values.yaml;
  waitFor = "flaresolverr";
}
