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
  name = "prowlarr";
  imageRepo = "lscr.io/linuxserver/prowlarr";
  imageTag = "2.3.0";
  port = 9696;
  configPvc = "prowlarr-config";
  apiKeySecret = "prowlarr-api-key";
  withSharedData = false;
}
