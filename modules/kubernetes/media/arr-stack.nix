{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/arr-stack-setup-done";
in
{
  systemd.services.arr-stack-setup = {
    description = "Setup *arr stack (Prowlarr, Sonarr, Radarr, qBittorrent)";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
      "arr-secrets-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "nfs-storage-setup.service"
      "arr-secrets-setup.service"
    ];
    # TIER 4: Media
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "arr-stack-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "*arr stack"

                wait_for_k3s
                wait_for_traefik
                wait_for_certificate

                setup_namespace "${ns}"
                wait_for_shared_data "${ns}"

                # Create config PVCs (shared-data is created by nfs-storage-setup)
                create_pvc "prowlarr-config" "${ns}" "1Gi"
                create_pvc "sonarr-config" "${ns}" "1Gi"
                create_pvc "sonarr-es-config" "${ns}" "1Gi"
                create_pvc "radarr-config" "${ns}" "1Gi"
                create_pvc "radarr-es-config" "${ns}" "1Gi"
                create_pvc "qbittorrent-config" "${ns}" "1Gi"

                # Prowlarr
                ${k8s.createLinuxServerDeployment {
                  name = "prowlarr";
                  namespace = ns;
                  image = "lscr.io/linuxserver/prowlarr:2.3.0";
                  port = 9696;
                  configPVC = "prowlarr-config";
                  apiKeySecret = "prowlarr-api-key";
                }}

                # Sonarr - uses shared-data with TRaSH Guides structure
                ${k8s.createLinuxServerDeployment {
                  name = "sonarr";
                  namespace = ns;
                  image = "lscr.io/linuxserver/sonarr:4.0.16";
                  port = 8989;
                  configPVC = "sonarr-config";
                  apiKeySecret = "sonarr-api-key";
                  resources = {
                    requests = {
                      cpu = "50m";
                      memory = "256Mi";
                    };
                    limits = {
                      memory = "2Gi";
                    };
                  };
                  extraVolumeMounts = [
                    "- name: data\n          mountPath: /data"
                  ];
                  extraVolumes = [
                    "- name: data\n        persistentVolumeClaim:\n          claimName: shared-data"
                  ];
                }}

                # Radarr - uses shared-data with TRaSH Guides structure
                ${k8s.createLinuxServerDeployment {
                  name = "radarr";
                  namespace = ns;
                  image = "lscr.io/linuxserver/radarr:6.0.4";
                  port = 7878;
                  configPVC = "radarr-config";
                  apiKeySecret = "radarr-api-key";
                  resources = {
                    requests = {
                      cpu = "50m";
                      memory = "256Mi";
                    };
                    limits = {
                      memory = "2Gi";
                    };
                  };
                  extraVolumeMounts = [
                    "- name: data\n          mountPath: /data"
                  ];
                  extraVolumes = [
                    "- name: data\n        persistentVolumeClaim:\n          claimName: shared-data"
                  ];
                }}

                # Sonarr ES - Spanish instance, separate config, same shared-data
                ${k8s.createLinuxServerDeployment {
                  name = "sonarr-es";
                  namespace = ns;
                  image = "lscr.io/linuxserver/sonarr:4.0.16";
                  port = 8989;
                  configPVC = "sonarr-es-config";
                  apiKeySecret = "sonarr-es-api-key";
                  resources = {
                    requests = {
                      cpu = "50m";
                      memory = "256Mi";
                    };
                    limits = {
                      memory = "2Gi";
                    };
                  };
                  extraVolumeMounts = [
                    "- name: data\n          mountPath: /data"
                  ];
                  extraVolumes = [
                    "- name: data\n        persistentVolumeClaim:\n          claimName: shared-data"
                  ];
                }}

                # Radarr ES - Spanish instance, separate config, same shared-data
                ${k8s.createLinuxServerDeployment {
                  name = "radarr-es";
                  namespace = ns;
                  image = "lscr.io/linuxserver/radarr:6.0.4";
                  port = 7878;
                  configPVC = "radarr-es-config";
                  apiKeySecret = "radarr-es-api-key";
                  resources = {
                    requests = {
                      cpu = "50m";
                      memory = "256Mi";
                    };
                    limits = {
                      memory = "2Gi";
                    };
                  };
                  extraVolumeMounts = [
                    "- name: data\n          mountPath: /data"
                  ];
                  extraVolumes = [
                    "- name: data\n        persistentVolumeClaim:\n          claimName: shared-data"
                  ];
                }}

                # qBittorrent - uses shared-data with TRaSH Guides structure
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: qbittorrent
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: qbittorrent
          template:
            metadata:
              labels:
                app: qbittorrent
            spec:
              containers:
              - name: qbittorrent
                image: lscr.io/linuxserver/qbittorrent:5.0.4
                ports:
                - containerPort: 8080
                - containerPort: 6881
                  protocol: TCP
                - containerPort: 6881
                  protocol: UDP
                env:
                - name: PUID
                  value: "${toString (serverConfig.puid or 1000)}"
                - name: PGID
                  value: "${toString (serverConfig.pgid or 1000)}"
                - name: TZ
                  value: "${serverConfig.timezone}"
                - name: WEBUI_PORT
                  value: "8080"
                resources:
                  requests:
                    cpu: 50m
                    memory: 128Mi
                  limits:
                    memory: 2Gi
                volumeMounts:
                - name: config
                  mountPath: /config
                - name: data
                  mountPath: /data
              volumes:
              - name: config
                persistentVolumeClaim:
                  claimName: qbittorrent-config
              - name: data
                persistentVolumeClaim:
                  claimName: shared-data
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: qbittorrent
          namespace: ${ns}
        spec:
          selector:
            app: qbittorrent
          ports:
          - name: webui
            port: 8080
            targetPort: 8080
          - name: bittorrent-tcp
            port: 6881
            targetPort: 6881
            protocol: TCP
          - name: bittorrent-udp
            port: 6881
            targetPort: 6881
            protocol: UDP
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: qbittorrent-bt
          namespace: ${ns}
        spec:
          type: LoadBalancer
          selector:
            app: qbittorrent
          ports:
          - name: bittorrent-tcp
            port: 6881
            targetPort: 6881
            protocol: TCP
          - name: bittorrent-udp
            port: 6881
            targetPort: 6881
            protocol: UDP
        EOF

                # Wait for pods
                wait_for_pod "${ns}" "app=prowlarr" 180
                wait_for_pod "${ns}" "app=sonarr" 180
                wait_for_pod "${ns}" "app=sonarr-es" 180
                wait_for_pod "${ns}" "app=radarr" 180
                wait_for_pod "${ns}" "app=radarr-es" 180
                wait_for_pod "${ns}" "app=qbittorrent" 180

                # Create IngressRoutes (ForwardAuth + local auth)
                create_ingress_route "prowlarr" "${ns}" "$(hostname prowlarr)" "prowlarr" "9696" "authentik-forward-auth:traefik-system"
                create_ingress_route "sonarr" "${ns}" "$(hostname sonarr)" "sonarr" "8989" "authentik-forward-auth:traefik-system"
                create_ingress_route "sonarr-es" "${ns}" "$(hostname sonarr-es)" "sonarr-es" "8989" "authentik-forward-auth:traefik-system"
                create_ingress_route "radarr" "${ns}" "$(hostname radarr)" "radarr" "7878" "authentik-forward-auth:traefik-system"
                create_ingress_route "radarr-es" "${ns}" "$(hostname radarr-es)" "radarr-es" "7878" "authentik-forward-auth:traefik-system"
                create_ingress_route "qbittorrent" "${ns}" "$(hostname qbit)" "qbittorrent" "8080" "authentik-forward-auth:traefik-system"

                # Pre-configure qBittorrent password
                # qBittorrent 5.x generates a random temp password on first start
                QBIT_PASSWORD=$(get_secret_value "${ns}" "qbittorrent-credentials" "PASSWORD")
                if [ -z "$QBIT_PASSWORD" ]; then
                  QBIT_PASSWORD=$(generate_password 16)
                  echo "Configuring qBittorrent password..."

                  # Wait for qBittorrent API
                  for i in $(seq 1 30); do
                    if $KUBECTL exec -n ${ns} deploy/qbittorrent -- curl -sf http://localhost:8080/api/v2/app/version 2>/dev/null; then
                      break
                    fi
                    sleep 3
                  done

                  # Get temp password from logs (qBittorrent 5.x prints it on startup)
                  TEMP_PASS=$($KUBECTL logs -n ${ns} deploy/qbittorrent 2>/dev/null | grep -oP 'temporary password is: \K\S+' | tail -1)
                  if [ -z "$TEMP_PASS" ]; then
                    TEMP_PASS="adminadmin"
                  fi

                  QBIT_COOKIE=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                    curl -s -c - -d "username=admin&password=$TEMP_PASS" http://localhost:8080/api/v2/auth/login 2>/dev/null | grep SID | awk '{print $NF}')
                  if [ -n "$QBIT_COOKIE" ]; then
                    $KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                      curl -s -b "SID=$QBIT_COOKIE" \
                      -d "json={\"web_ui_password\":\"$QBIT_PASSWORD\",\"save_path\":\"/data/torrents\",\"temp_path\":\"/data/torrents/incomplete\",\"temp_path_enabled\":true}" \
                      http://localhost:8080/api/v2/app/setPreferences 2>/dev/null
                    echo "qBittorrent password and save path configured"
                  else
                    echo "WARNING: Could not authenticate to qBittorrent, password not set"
                  fi
                  store_credentials "${ns}" "qbittorrent-credentials" \
                    "USER=admin" "PASSWORD=$QBIT_PASSWORD" "URL=https://$(hostname qbit)"
                fi

                print_success "*arr stack" \
                  "URLs:" \
                  "  Prowlarr: https://$(hostname prowlarr)" \
                  "  Sonarr: https://$(hostname sonarr)" \
                  "  Sonarr ES: https://$(hostname sonarr-es)" \
                  "  Radarr: https://$(hostname radarr)" \
                  "  Radarr ES: https://$(hostname radarr-es)" \
                  "  qBittorrent: https://$(hostname qbit)" \
                  "" \
                  "Sonarr-ES/Radarr-ES: instances for Spanish content" \
                  "Prowlarr syncs Spanish indexers only to ES instances"

                create_marker "${markerFile}"
      '';
    };
  };
}
