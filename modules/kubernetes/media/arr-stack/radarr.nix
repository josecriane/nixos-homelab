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
  name = "radarr";
  imageRepo = "lscr.io/linuxserver/radarr";
  imageTag = "6.0.4";
  port = 7878;
  configPvc = "radarr-config";
  apiKeySecret = "radarr-api-key";
  memReq = "256Mi";
  memLim = "2Gi";
  cardType = "Radarr";
  cardPaths = [
    "/api/v3/health"
    "/api/v3/queue"
    "/api/v3/wanted/missing"
  ];
  dashboard = {
    title = "Radarr";
    icon = "fas fa-video";
    subtitle = "Movies";
    sort = 30;
  };
}
