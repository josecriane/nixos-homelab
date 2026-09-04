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
  imageTag = "2.3.0";
  port = 9696;
  configPvc = "prowlarr-config";
  apiKeySecret = "prowlarr-api-key";
  withSharedData = false;
}
