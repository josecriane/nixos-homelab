{
  config,
  k8s,
  lib,
  serverConfig,
  ...
}:

let
  h = k8s.hostname;
  ns = "homer";
  proxyBase = "https://${h "home"}/proxy";
  pingUrl = w: "https://${h "services"}/api/ping/${w.namespace}/${w.name}";

  dash = config.dashboard;
  homerImage = {
    repository = "b4bz/homer";
    tag = "v24.11.3";
  };
  toolsImage = {
    repository = "alpine/k8s";
    tag = "1.35.9";
  };
  generate = "/scripts/generate.sh";

  statusWorkload = item: if item.ping != null then item.ping else item.workload;

  mkItem =
    key: item:
    {
      name = item.title;
      icon = item.icon;
      subtitle = item.subtitle;
      url = item.url;
      target = "_blank";
    }
    // lib.optionalAttrs (item.tag != null) { tag = item.tag; }
    // lib.optionalAttrs (item.workload != null) {
      workload = "${item.workload.namespace}/${item.workload.name}";
    }
    // (
      if item.card != null then
        {
          type = item.card.type;
          endpoint = "${proxyBase}/${key}";
        }
        // lib.optionalAttrs (item.card.apiKey != null) { apikey = "proxied"; }
        // item.card.extra
      else if statusWorkload item != null then
        {
          type = "Ping";
          method = "GET";
          endpoint = pingUrl (statusWorkload item);
        }
      else
        { }
    );

  itemsOf =
    group:
    lib.sort
      (
        a: b:
        if a.value.sort != b.value.sort then a.value.sort < b.value.sort else a.value.title < b.value.title
      )
      (
        lib.filter (i: i.value.enable && i.value.group == group) (
          lib.mapAttrsToList (name: value: { inherit name value; }) dash.items
        )
      );

  sortedGroups = lib.sort (a: b: a.value.sort < b.value.sort) (
    lib.mapAttrsToList (name: value: { inherit name value; }) dash.groups
  );

  services = lib.filter (g: g.items != [ ]) (
    map (g: {
      name = g.value.title;
      icon = g.value.icon;
      items = map (i: mkItem i.name i.value) (itemsOf g.name);
    }) sortedGroups
  );

  template = {
    title = "Homelab";
    subtitle = serverConfig.domain;
    logo = false;
    header = true;
    footer = false;
    theme = "default";
    columns = "3";
    defaults = {
      layout = "list";
      colorTheme = "auto";
    };
    colors = {
      light = {
        highlight-primary = "#3367d6";
        highlight-secondary = "#4285f4";
        highlight-hover = "#5a95f5";
        background = "#f5f5f5";
        card-background = "#ffffff";
        text = "#363636";
        text-header = "#ffffff";
        text-title = "#303030";
        text-subtitle = "#424242";
        card-shadow = "rgba(0, 0, 0, 0.1)";
        link = "#3273dc";
        link-hover = "#363636";
      };
      dark = {
        highlight-primary = "#3367d6";
        highlight-secondary = "#4285f4";
        highlight-hover = "#5a95f5";
        background = "#131313";
        card-background = "#2b2b2b";
        text = "#eaeaea";
        text-header = "#ffffff";
        text-title = "#fafafa";
        text-subtitle = "#f5f5f5";
        card-shadow = "rgba(0, 0, 0, 0.4)";
        link = "#3273dc";
        link-hover = "#ffdd57";
      };
    };
    inherit services;
  };

  rbac = k8s.applyManifestsScript {
    name = "homer-rbac";
    manifests = [ ./rbac.yaml ];
    substitutions.NAMESPACE = ns;
  };

  templateMounts = [
    {
      path = "/template/template.json";
      subPath = "template.json";
    }
    {
      path = generate;
      subPath = "generate.sh";
    }
  ];
in
k8s.createHelmRelease {
  name = "homer";
  namespace = ns;
  tier = "core";
  chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
  version = "4.6.1";
  waitFor = "homer";
  preScript = rbac;
  ingress = {
    host = "home";
    service = "homer";
    port = 8080;
  };
  values = {
    defaultPodOptions.automountServiceAccountToken = true;
    controllers.homer = {
      strategy = "Recreate";
      serviceAccount.name = "homer";
      initContainers = {
        "01-assets" = {
          image = homerImage;
          command = [
            "sh"
            "-c"
            "cp -Rn /www/default-assets/. /www/assets/"
          ];
        };
        "02-config" = {
          image = toolsImage;
          command = [
            "bash"
            generate
          ];
        };
      };
      containers = {
        main = {
          image = homerImage;
          resources = {
            requests = {
              cpu = "10m";
              memory = "16Mi";
            };
            limits.memory = "64Mi";
          };
        };
        refresh = {
          image = toolsImage;
          command = [
            "bash"
            "-c"
            "while true; do sleep 60; bash ${generate}; done"
          ];
          resources = {
            requests = {
              cpu = "10m";
              memory = "32Mi";
            };
            limits.memory = "128Mi";
          };
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
      data = {
        "template.json" = builtins.toJSON template;
        "generate.sh" = builtins.readFile ./generate.sh;
      };
    };
    persistence = {
      assets = {
        type = "emptyDir";
        globalMounts = [ { path = "/www/assets"; } ];
      };
      template = {
        type = "configMap";
        name = "homer";
        advancedMounts.homer = {
          "02-config" = templateMounts;
          refresh = templateMounts;
        };
      };
    };
  };
}
