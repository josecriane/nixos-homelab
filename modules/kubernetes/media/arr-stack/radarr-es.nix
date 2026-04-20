{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  helpers = import ./lib.nix { inherit lib pkgs serverConfig nixos-k8s; };
in
helpers.mkArrRelease {
  name = "radarr-es";
  imageRepo = "lscr.io/linuxserver/radarr";
  imageTag = "6.0.4";
  port = 7878;
  configPvc = "radarr-es-config";
  apiKeySecret = "radarr-es-api-key";
  memReq = "256Mi";
  memLim = "2Gi";
}
