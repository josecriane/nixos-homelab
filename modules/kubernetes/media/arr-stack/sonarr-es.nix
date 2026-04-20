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
  name = "sonarr-es";
  imageRepo = "lscr.io/linuxserver/sonarr";
  imageTag = "4.0.16";
  port = 8989;
  configPvc = "sonarr-es-config";
  apiKeySecret = "sonarr-es-api-key";
  memReq = "256Mi";
  memLim = "2Gi";
}
