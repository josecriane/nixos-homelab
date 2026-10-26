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
  name = "prowlarr";
  imageRepo = "lscr.io/linuxserver/prowlarr";
  imageTag = "2.6.5";
  port = 9696;
  configPvc = "prowlarr-config";
  apiKeySecret = "prowlarr-api-key";
  withSharedData = false;
  widgetType = "prowlarr";
  dashboard = {
    title = "Prowlarr";
    icon = "sh-prowlarr";
    subtitle = "Indexers";
    sort = 70;
  };
}
