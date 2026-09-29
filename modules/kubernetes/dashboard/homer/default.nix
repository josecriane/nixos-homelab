# Homer - Lightweight dashboard
# Replaces Homarr (~559MB) with a static dashboard (~10-20MB).
# Declared via bjw-s/app-template Helm library chart. The dashboard's
# config.yml is built from the entries each module registers in
# `homelab.dashboard`, then embedded in a chart-managed ConfigMap and mounted
# into the container.
{
  config,
  k8s,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let

  h = k8s.hostname;

  switchboardUrl = "https://${h "services"}";
  pingUrl = ns: name: "${switchboardUrl}/api/ping/${ns}/${name}";

  dash = config.homelab.dashboard;

  mkItem =
    item:
    "      - name: \"${item.title}\"\n        icon: \"${item.icon}\"\n        subtitle: \"${item.subtitle}\"\n        url: \"${item.url}\"\n        target: \"_blank\""
    + lib.optionalString (item.tag != null) "\n        tag: \"${item.tag}\""
    + lib.optionalString (item.ping != null) (
      "\n        type: \"Ping\"\n        apiurl: \"${pingUrl item.ping.namespace item.ping.name}\""
    );

  itemsOf =
    key:
    lib.sort (a: b: if a.sort != b.sort then a.sort < b.sort else a.title < b.title) (
      lib.filter (i: i.enable && i.group == key) (lib.attrValues dash.items)
    );

  renderGroup =
    key: group:
    let
      items = itemsOf key;
    in
    lib.optionalString (items != [ ]) (
      "  - name: \"${group.title}\"\n    icon: \"${group.icon}\"\n    items:\n"
      + lib.concatStringsSep "\n" (map mkItem items)
    );

  sortedGroups = lib.sort (a: b: a.value.sort < b.value.sort) (
    lib.mapAttrsToList (name: value: { inherit name value; }) dash.groups
  );

  allGroups = lib.concatStringsSep "\n" (
    lib.filter (x: x != "") (map (g: renderGroup g.name g.value) sortedGroups)
  );

  homerConfigYaml = ''
    ---
    title: "Homelab"
    subtitle: "${serverConfig.domain}"
    logo: false

    header: true
    footer: false

    theme: default

    columns: "3"

    defaults:
      layout: list
      colorTheme: auto

    colors:
      light:
        highlight-primary: "#3367d6"
        highlight-secondary: "#4285f4"
        highlight-hover: "#5a95f5"
        background: "#f5f5f5"
        card-background: "#ffffff"
        text: "#363636"
        text-header: "#ffffff"
        text-title: "#303030"
        text-subtitle: "#424242"
        card-shadow: rgba(0, 0, 0, 0.1)
        link: "#3273dc"
        link-hover: "#363636"
      dark:
        highlight-primary: "#3367d6"
        highlight-secondary: "#4285f4"
        highlight-hover: "#5a95f5"
        background: "#131313"
        card-background: "#2b2b2b"
        text: "#eaeaea"
        text-header: "#ffffff"
        text-title: "#fafafa"
        text-subtitle: "#f5f5f5"
        card-shadow: rgba(0, 0, 0, 0.4)
        link: "#3273dc"
        link-hover: "#ffdd57"

    services:
    ${allGroups}
  '';
in
k8s.createHelmRelease {
  name = "homer";
  namespace = "homer";
  tier = "core";
  chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
  version = "4.6.1";
  waitFor = "homer";
  ingress = {
    host = "home";
    service = "homer";
    port = 8080;
  };
  values = {
    controllers.homer = {
      strategy = "Recreate";
      containers.main = {
        image = {
          repository = "b4bz/homer";
          tag = "v24.11.3";
        };
        resources = {
          requests = {
            cpu = "10m";
            memory = "16Mi";
          };
          limits.memory = "64Mi";
        };
      };
    };
    service.homer = {
      controller = "homer";
      ports.http = {
        port = 8080;
        targetPort = 8080;
      };
    };
    configMaps.config = {
      enabled = true;
      data."config.yml" = homerConfigYaml;
    };
    persistence.config-file = {
      enabled = true;
      type = "configMap";
      name = "homer";
      advancedMounts.homer.main = [
        {
          path = "/www/assets/config.yml";
          subPath = "config.yml";
        }
      ];
    };
  };
}
