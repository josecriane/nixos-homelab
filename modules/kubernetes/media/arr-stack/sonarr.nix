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
  cardType = "Sonarr";
  cardPaths = [
    "/api/v3/health"
    "/api/v3/queue"
    "/api/v3/wanted/missing"
  ];
  dashboard = {
    title = "Sonarr";
    icon = "fas fa-tv";
    subtitle = "TV Shows";
    sort = 10;
  };
}
