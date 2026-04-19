# Homer - Lightweight dashboard
# Replaces Homarr (~559MB) with a static dashboard (~10-20MB)
{
  config,
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "homer";
  markerFile = "/var/lib/homer-setup-done";

  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;
  h = k8s.hostname;

  # Build a YAML item (2 extra spaces indent for nesting under items:)
  serviceManagerUrl = "https://${h "services"}";
  pingUrl = ns: name: "${serviceManagerUrl}/api/ping/${ns}/${name}";

  mkItem =
    {
      name,
      icon,
      subtitle,
      url,
      tag ? null,
      type ? null,
      apiurl ? null,
    }:
    "      - name: \"${name}\"\n        icon: \"${icon}\"\n        subtitle: \"${subtitle}\"\n        url: \"${url}\"\n        target: \"_blank\""
    + lib.optionalString (tag != null) "\n        tag: \"${tag}\""
    + lib.optionalString (type != null) "\n        type: \"${type}\""
    + lib.optionalString (apiurl != null) "\n        apiurl: \"${apiurl}\"";

  # Join items with newlines
  joinItems = items: lib.concatStringsSep "\n" (lib.filter (x: x != "") items);

  # Build a group section
  mkGroup =
    name: icon: items:
    let
      activeItems = lib.filter (x: x != "") items;
    in
    lib.optionalString (activeItems != [ ]) (
      "  - name: \"${name}\"\n    icon: \"${icon}\"\n    items:\n" + joinItems activeItems
    );

  cloudGroup = mkGroup "Cloud" "fas fa-cloud" (
    lib.optional (enabled "vaultwarden") (mkItem {
      name = "Vaultwarden";
      icon = "fas fa-key";
      subtitle = "Password Manager";
      url = "https://${h "vault"}";
    })
    ++ lib.optional (enabled "nextcloud") (mkItem {
      name = "Nextcloud";
      icon = "fas fa-cloud";
      subtitle = "Cloud Storage";
      url = "https://${h "cloud"}";
    })
    ++ lib.optional (enabled "immich") (mkItem {
      name = "Immich";
      icon = "fas fa-images";
      subtitle = "Photo Backup";
      url = "https://${h "photos"}";
    })
    ++ lib.optional (enabled "syncthing") (mkItem {
      name = "Syncthing";
      icon = "fas fa-sync";
      subtitle = "File Sync";
      url = "https://${h "sync"}";
    })
  );

  mediaGroup = mkGroup "Media" "fas fa-play-circle" (
    lib.optionals (enabled "media") [
      (mkItem {
        name = "Jellyfin";
        icon = "fas fa-film";
        subtitle = "Media Server";
        url = "https://${h "jellyfin"}";
      })
      (mkItem {
        name = "Jellyseerr";
        icon = "fas fa-search";
        subtitle = "Media Requests";
        url = "https://${h "requests"}";
      })
      (mkItem {
        name = "Kavita";
        icon = "fas fa-book-reader";
        subtitle = "Manga/Comics";
        url = "https://${h "kavita"}";
      })
    ]
  );

  downloadsGroup = mkGroup "Downloads & Management" "fas fa-tasks" (
    lib.optionals (enabled "media") [
      (mkItem {
        name = "Sonarr";
        icon = "fas fa-tv";
        subtitle = "TV Shows";
        url = "https://${h "sonarr"}";
      })
      (mkItem {
        name = "Sonarr ES";
        icon = "fas fa-tv";
        subtitle = "Series (ES)";
        url = "https://${h "sonarr-es"}";
        tag = "ES";
      })
      (mkItem {
        name = "Radarr";
        icon = "fas fa-video";
        subtitle = "Movies";
        url = "https://${h "radarr"}";
      })
      (mkItem {
        name = "Radarr ES";
        icon = "fas fa-video";
        subtitle = "Movies (ES)";
        url = "https://${h "radarr-es"}";
        tag = "ES";
      })
      (mkItem {
        name = "Lidarr";
        icon = "fas fa-music";
        subtitle = "Music";
        url = "https://${h "lidarr"}";
      })
      (mkItem {
        name = "Bazarr";
        icon = "fas fa-closed-captioning";
        subtitle = "Subtitles";
        url = "https://${h "bazarr"}";
      })
      (mkItem {
        name = "Prowlarr";
        icon = "fas fa-search-plus";
        subtitle = "Indexers";
        url = "https://${h "prowlarr"}";
      })
      (mkItem {
        name = "qBittorrent";
        icon = "fas fa-download";
        subtitle = "Downloads";
        url = "https://${h "qbit"}";
      })
      (mkItem {
        name = "Bookshelf";
        icon = "fas fa-book";
        subtitle = "Ebooks";
        url = "https://${h "books"}";
      })
      (mkItem {
        name = "Kitsunarr";
        icon = "fas fa-paw";
        subtitle = "Anime Management";
        url = "https://${h "kitsunarr"}";
      })
    ]
  );

  knowledgeGroup = mkGroup "Knowledge" "fas fa-brain" (
    lib.optional (enabled "kiwix") (mkItem {
      name = "Kiwix";
      icon = "fab fa-wikipedia-w";
      subtitle = "Offline Knowledge";
      url = "https://${h "wiki"}";
      type = "Ping";
      apiurl = pingUrl "kiwix" "kiwix-serve";
    })
    ++ lib.optional (enabled "openstreetmap") (mkItem {
      name = "OpenStreetMap";
      icon = "fas fa-map-marked-alt";
      subtitle = "Offline Maps";
      url = "https://${h "maps"}";
      type = "Ping";
      apiurl = pingUrl "openstreetmap" "openstreetmap";
    })
  );

  monitoringGroup = mkGroup "Monitoring" "fas fa-chart-line" (
    lib.optionals (enabled "monitoring") [
      (mkItem {
        name = "Grafana";
        icon = "fas fa-chart-area";
        subtitle = "Dashboards";
        url = "https://${h "grafana"}";
        type = "Ping";
        apiurl = pingUrl "monitoring" "grafana";
      })
      (mkItem {
        name = "Prometheus";
        icon = "fas fa-database";
        subtitle = "Metrics";
        url = "https://${h "prometheus"}";
        type = "Ping";
        apiurl = pingUrl "monitoring" "prometheus-server";
      })
      (mkItem {
        name = "Alertmanager";
        icon = "fas fa-bell";
        subtitle = "Alerts";
        url = "https://${h "alertmanager"}";
        type = "Ping";
        apiurl = pingUrl "monitoring" "alertmanager";
      })
    ]
  );

  infraGroup = mkGroup "Infrastructure" "fas fa-server" (
    [
      (mkItem {
        name = "Traefik";
        icon = "fas fa-route";
        subtitle = "Ingress Controller";
        url = "https://${h "traefik"}";
      })
    ]
    ++ lib.optional (enabled "authentik") (mkItem {
      name = "Authentik";
      icon = "fas fa-shield-alt";
      subtitle = "SSO/Identity";
      url = "https://${h "auth"}";
    })
    ++ lib.optional (enabled "dashboard") (mkItem {
      name = "Service Manager";
      icon = "fas fa-power-off";
      subtitle = "Start/Stop Services";
      url = "https://${h "services"}";
    })
    ++ [
      (mkItem {
        name = "Omada Controller";
        icon = "fas fa-wifi";
        subtitle = "Network Management";
        url = "https://${h "omada"}";
      })
    ]
  );

  allGroups = lib.concatStringsSep "\n" (
    lib.filter (x: x != "") [
      cloudGroup
      mediaGroup
      downloadsGroup
      knowledgeGroup
      monitoringGroup
      infraGroup
    ]
  );

  homerConfigYaml = pkgs.writeText "homer-config.yml" ''
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
{
  systemd.services.homer-setup = {
    description = "Setup Homer dashboard";
    after = [ "k3s-storage.target" ];
    requires = [ "k3s-storage.target" ];
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "homer-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "Homer"

                wait_for_k3s
                wait_for_traefik
                wait_for_certificate
                ensure_namespace "${ns}"

                # Create ConfigMap from pre-built YAML
                $KUBECTL create configmap homer-config -n ${ns} \
                  --from-file=config.yml=${homerConfigYaml} \
                  --dry-run=client -o yaml | $KUBECTL apply -f -
                echo "Homer config created"

                # Deploy Homer
                cat <<'EOF' | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: homer
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: homer
          template:
            metadata:
              labels:
                app: homer
            spec:
              containers:
              - name: homer
                image: b4bz/homer:v24.11.3
                ports:
                - containerPort: 8080
                resources:
                  requests:
                    cpu: 10m
                    memory: 16Mi
                  limits:
                    memory: 64Mi
                volumeMounts:
                - name: config
                  mountPath: /www/assets/config.yml
                  subPath: config.yml
              volumes:
              - name: config
                configMap:
                  name: homer-config
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: homer
          namespace: ${ns}
        spec:
          selector:
            app: homer
          ports:
          - port: 8080
            targetPort: 8080
        EOF

                wait_for_deployment "${ns}" "homer" 120

                create_ingress_route "homer" "${ns}" "$(hostname home)" "homer" "8080"

                print_success "Homer" \
                  "URL: https://$(hostname home)"

                create_marker "${markerFile}"
      '';
    };
  };
}
