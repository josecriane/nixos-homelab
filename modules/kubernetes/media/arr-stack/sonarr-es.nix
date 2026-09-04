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
  name = "sonarr-es";
  imageRepo = "lscr.io/linuxserver/sonarr";
  imageTag = "4.0.16";
  port = 8989;
  configPvc = "sonarr-es-config";
  apiKeySecret = "sonarr-es-api-key";
  memReq = "256Mi";
  memLim = "2Gi";
}
