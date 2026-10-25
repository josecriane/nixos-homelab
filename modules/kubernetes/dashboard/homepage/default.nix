{
  config,
  k8s,
  lib,
  ...
}:

let
  ns = "homepage";
  host = k8s.hostname "home";
  dash = config.dashboard;
  pausedGroup = "Apagados";

  homepageImage = {
    repository = "ghcr.io/gethomepage/homepage";
    tag = "v2.6.0";
  };
  toolsImage = {
    repository = "alpine/k8s";
    tag = "1.35.9";
  };
  generate = "/template/generate.sh";

  helmLiteral = s: builtins.replaceStrings [ "{{" "}}" ] [ "{{ `{{` }}" "{{ `}}` }}" ] s;

  envName =
    key: field:
    "HOMEPAGE_VAR_${lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] key)}_${lib.toUpper field}";

  activeItems = lib.filterAttrs (_: item: item.enable) dash.items;

  secretRefs = lib.flatten (
    lib.mapAttrsToList (
      key: item:
      if item.widget == null then
        [ ]
      else
        lib.mapAttrsToList (field: ref: {
          env = envName key field;
          inherit (ref) namespace secret key;
        }) item.widget.secrets
    ) activeItems
  );

  mkWidget =
    key: widget:
    {
      inherit (widget) type url;
    }
    // lib.mapAttrs (field: _: helmLiteral "{{${envName key field}}}") widget.secrets
    // widget.options;

  mkItem = key: item: {
    title = item.title;
    monitor = item.monitor;
    workload =
      if item.workload == null then null else "${item.workload.namespace}/${item.workload.name}";
    props = {
      icon = item.icon;
      href = item.url;
      description = item.subtitle;
    }
    // lib.optionalAttrs (item.workload != null) (
      {
        namespace = item.workload.namespace;
        app = item.workload.name;
      }
      // lib.optionalAttrs (item.workload.selector != null) { podSelector = item.workload.selector; }
    )
    // lib.optionalAttrs (item.widget != null) { widget = mkWidget key item.widget; };
  };

  itemsOf =
    group:
    lib.sort
      (
        a: b:
        if a.value.sort != b.value.sort then a.value.sort < b.value.sort else a.value.title < b.value.title
      )
      (
        lib.filter (i: i.value.group == group) (
          lib.mapAttrsToList (name: value: { inherit name value; }) activeItems
        )
      );

  sortedGroups = lib.sort (a: b: a.value.sort < b.value.sort) (
    lib.mapAttrsToList (name: value: { inherit name value; }) dash.groups
  );

  template = {
    paused = pausedGroup;
    groups = map (g: {
      name = g.value.title;
      items = map (i: mkItem i.name i.value) (itemsOf g.name);
    }) sortedGroups;
  };

  groupLayout = icon: {
    inherit icon;
    style = "row";
    columns = 3;
  };

  layoutEntries =
    map (g: {
      name = g.value.title;
      value = groupLayout g.value.icon;
    }) sortedGroups
    ++ [
      {
        name = pausedGroup;
        value = groupLayout "mdi-sleep" // {
          initiallyCollapsed = true;
        };
      }
    ];

  layoutJson = "{${
    lib.concatMapStringsSep "," (
      e: "${builtins.toJSON e.name}:${builtins.toJSON e.value}"
    ) layoutEntries
  }}";

  settings = {
    title = "Homelab";
    language = "es";
    headerStyle = "boxed";
    hideVersion = true;
    statusStyle = "dot";
    showStats = true;
    useEqualHeights = true;
    target = "_blank";
  };

  settingsJson = "${lib.removeSuffix "}" (builtins.toJSON settings)},\"layout\":${layoutJson}}";

  infoWidgets = [
    {
      kubernetes = {
        cluster = {
          show = true;
          cpu = true;
          memory = true;
          showLabel = true;
          label = "cluster";
        };
        nodes = {
          show = true;
          cpu = true;
          memory = true;
          showLabel = true;
        };
      };
    }
    {
      datetime = {
        text_size = "xl";
        format = {
          dateStyle = "long";
          timeStyle = "short";
          hourCycle = "h23";
        };
      };
    }
  ];

  kubernetes = {
    mode = "cluster";
    ingress = false;
  };

  rbac = k8s.applyManifestsScript {
    name = "homepage-rbac";
    manifests = [ ./rbac.yaml ];
    substitutions.NAMESPACE = ns;
  };

  secretLine = ref: ''
    VALUE=$(get_secret_value "${ref.namespace}" "${ref.secret}" "${ref.key}")
    if [ -z "$VALUE" ]; then
      echo "WARN: ${ref.namespace}/${ref.secret} has no ${ref.key}, ${ref.env} stays empty"
    fi
    KEYS+=("--from-literal=${ref.env}=$VALUE")
  '';

  preScript = ''
    if $HELM status homer -n homer >/dev/null 2>&1; then
      $HELM uninstall homer -n homer
    fi
    $KUBECTL delete namespace homer --ignore-not-found --wait=false
    $KUBECTL delete clusterrole homer-dashboard --ignore-not-found
    $KUBECTL delete clusterrolebinding homer-dashboard --ignore-not-found
    $KUBECTL get ingressroutes,middlewares -A -o json \
      | $JQ -r '.items[] | select(.metadata.name | startswith("homer-proxy-")) | "\(.kind | ascii_downcase) \(.metadata.name) \(.metadata.namespace)"' \
      | while read -r kind name namespace; do
          $KUBECTL -n "$namespace" delete "$kind" "$name" --ignore-not-found
        done
    rm -f /var/lib/homer-setup-done /var/lib/homer-proxy-setup-done

    ${rbac}

    KEYS=()
    ${lib.concatMapStrings secretLine secretRefs}
    $KUBECTL -n ${ns} create secret generic homepage-keys ''${KEYS[@]+"''${KEYS[@]}"} \
      --dry-run=client -o yaml | $KUBECTL apply -f -
  '';

  probe = {
    enabled = true;
    custom = true;
    spec.httpGet = {
      path = "/api/healthcheck";
      port = 3000;
      httpHeaders = [
        {
          name = "Host";
          value = host;
        }
      ];
    };
  };

  templateMount = [ { path = "/template"; } ];
in
k8s.createHelmRelease {
  name = "homepage";
  namespace = ns;
  tier = "extras";
  chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
  version = "4.6.1";
  waitFor = "homepage";
  inherit preScript;
  ingress = {
    host = "home";
    service = "homepage";
    port = 3000;
  };
  values = {
    defaultPodOptions.automountServiceAccountToken = true;
    controllers.homepage = {
      strategy = "Recreate";
      serviceAccount.name = "homepage";
      initContainers.config = {
        image = toolsImage;
        command = [
          "bash"
          generate
        ];
      };
      containers = {
        main = {
          image = homepageImage;
          env = {
            HOMEPAGE_ALLOWED_HOSTS = host;
          };
          envFrom = [ { secretRef.name = "homepage-keys"; } ];
          probes = {
            startup = probe // {
              spec = probe.spec // {
                failureThreshold = 30;
                periodSeconds = 5;
              };
            };
            readiness = probe;
            liveness = probe;
          };
          resources = {
            requests = {
              cpu = "50m";
              memory = "192Mi";
            };
            limits.memory = "512Mi";
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
    service.homepage = {
      controller = "homepage";
      ports.http = {
        port = 3000;
        targetPort = 3000;
      };
    };
    configMaps.config = {
      enabled = true;
      data = {
        "template.json" = builtins.toJSON template;
        "generate.sh" = builtins.readFile ./generate.sh;
        "settings.yaml" = settingsJson;
        "kubernetes.yaml" = builtins.toJSON kubernetes;
        "widgets.yaml" = builtins.toJSON infoWidgets;
        "bookmarks.yaml" = "[]";
      };
    };
    persistence = {
      config = {
        type = "emptyDir";
        globalMounts = [ { path = "/app/config"; } ];
      };
      template = {
        type = "configMap";
        name = "homepage";
        advancedMounts.homepage = {
          config = templateMount;
          refresh = templateMount;
        };
      };
    };
  };
}
