{
  k8s,
  lib,
  pkgs,
  serverConfig,
  ...
}@args:

let
  helpers = import ./lib.nix args;
in
helpers.mkArrRelease {
  name = "sonarr";
  imageRepo = "lscr.io/linuxserver/sonarr";
  imageTag = "4.0.16";
  port = 8989;
  configPvc = "sonarr-config";
  apiKeySecret = "sonarr-api-key";
  memReq = "256Mi";
  memLim = "2Gi";
}
