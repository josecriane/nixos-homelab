# OpenStreetMap - Offline world maps
# Serves PMTiles via go-pmtiles with MapLibre GL JS frontend
# Map data stored on NAS (cloudPaths.openstreetmap), served via NFS-backed PV
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "openstreetmap";
  markerFile = "/var/lib/openstreetmap-setup-done";

  # Find NAS with cloudPaths.openstreetmap
  cloudNas = lib.findFirst (
    cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) ? "openstreetmap"
  ) null (lib.attrValues (serverConfig.nas or { }));
  cloudHostPath =
    if cloudNas != null then "/mnt/${cloudNas.hostname}/${cloudNas.cloudPaths.openstreetmap}" else null;
in
{
  # =========================================
  # openstreetmap-setup: Deploy go-pmtiles + viewer + ingress
  # =========================================
  systemd.services.openstreetmap-setup = {
    description = "Setup OpenStreetMap offline maps server";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [ "nfs-storage-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "openstreetmap-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "OpenStreetMap"

                wait_for_k3s
                wait_for_certificate
                setup_namespace "${ns}"

                # Ensure NAS PV exists
                PV_PHASE=$($KUBECTL get pv openstreetmap-data-pv -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ -n "$PV_PHASE" ]; then
                  echo "PV openstreetmap-data-pv found ($PV_PHASE)"
                else
                  ${
                    if cloudHostPath != null then
                      ''
                                  echo "PV openstreetmap-data-pv not found, creating..."
                                  mkdir -p "${cloudHostPath}" 2>/dev/null || true
                                  chmod 777 "${cloudHostPath}" 2>/dev/null || true
                                  cat <<PVEOF | $KUBECTL apply -f -
                        apiVersion: v1
                        kind: PersistentVolume
                        metadata:
                          name: openstreetmap-data-pv
                        spec:
                          capacity:
                            storage: 1Ti
                          accessModes:
                            - ReadWriteOnce
                          persistentVolumeReclaimPolicy: Retain
                          storageClassName: nas-storage
                          hostPath:
                            path: ${cloudHostPath}
                            type: DirectoryOrCreate
                        PVEOF
                                  echo "PV openstreetmap-data-pv created"
                      ''
                    else
                      ''
                        echo "WARNING: PV openstreetmap-data-pv not found and no cloudPaths.openstreetmap configured"
                      ''
                  }
                fi

                # NAS-backed PVC
                EXISTING_PVC=$($KUBECTL get pvc openstreetmap-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$EXISTING_PVC" = "Bound" ]; then
                  echo "PVC openstreetmap-data already Bound, skipping"
                else
                  cat <<PVCEOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: openstreetmap-data
          namespace: ${ns}
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: nas-storage
          resources:
            requests:
              storage: 1Ti
          volumeName: openstreetmap-data-pv
        PVCEOF
                  echo "PVC openstreetmap-data created"
                  for i in $(seq 1 30); do
                    STATUS=$($KUBECTL get pvc openstreetmap-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
                    if [ "$STATUS" = "Bound" ]; then
                      echo "PVC openstreetmap-data: Bound"
                      break
                    fi
                    echo "  PVC status: $STATUS ($i/30)"
                    sleep 5
                  done
                fi

                # Create MapLibre viewer ConfigMap
                cat <<'VIEWEREOF' | $KUBECTL apply -f -
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: maplibre-viewer
          namespace: ${ns}
        data:
          index.html: |
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1.0" />
              <title>Offline Maps</title>
              <link rel="stylesheet" href="https://unpkg.com/maplibre-gl@5.1.0/dist/maplibre-gl.css" />
              <script src="https://unpkg.com/maplibre-gl@5.1.0/dist/maplibre-gl.js"></script>
              <script src="https://unpkg.com/pmtiles@4.2.1/dist/pmtiles.js"></script>
              <style>
                body { margin: 0; padding: 0; }
                #map { position: absolute; top: 0; bottom: 0; width: 100%; }
              </style>
            </head>
            <body>
              <div id="map"></div>
              <script>
                const protocol = new pmtiles.Protocol();
                maplibregl.addProtocol("pmtiles", protocol.tile);

                const PMTILES_URL = "pmtiles://" + window.location.origin + "/tiles/world.pmtiles";

                const map = new maplibregl.Map({
                  container: "map",
                  zoom: 3,
                  center: [0, 30],
                  style: {
                    version: 8,
                    glyphs: "https://cdn.protomaps.com/fonts/pbf/{fontstack}/{range}.pbf",
                    sources: {
                      protomaps: {
                        type: "vector",
                        url: PMTILES_URL,
                        attribution: '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a>'
                      }
                    },
                    layers: protomapsL.default("protomaps", "light")
                  }
                });

                map.addControl(new maplibregl.NavigationControl());
                map.addControl(new maplibregl.GeolocateControl({
                  positionOptions: { enableHighAccuracy: true },
                  trackUserLocation: true
                }));
              </script>
              <script src="https://unpkg.com/protomaps-themes-base@latest/dist/index.js"></script>
              <script>
                // Re-apply style with protomaps theme once loaded
                if (typeof protomapsL !== "undefined") {
                  map.setStyle({
                    version: 8,
                    glyphs: "https://cdn.protomaps.com/fonts/pbf/{fontstack}/{range}.pbf",
                    sources: {
                      protomaps: {
                        type: "vector",
                        url: PMTILES_URL,
                        attribution: '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a>'
                      }
                    },
                    layers: protomapsL.default("protomaps", "light")
                  });
                }
              </script>
            </body>
            </html>
          nginx.conf: |
            server {
              listen 8080;

              location / {
                root /usr/share/nginx/html;
                index index.html;
              }

              location /tiles/ {
                proxy_pass http://localhost:8081/;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_buffering off;
              }
            }
        VIEWEREOF
                echo "MapLibre viewer ConfigMap created"

                # Deploy go-pmtiles + nginx viewer
                cat <<'EOF' | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: openstreetmap
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: openstreetmap
          template:
            metadata:
              labels:
                app: openstreetmap
            spec:
              containers:
              - name: tiles
                image: protomaps/go-pmtiles:v1.22.3
                args: ["serve", "/data", "--port=8081", "--cors=*"]
                ports:
                - containerPort: 8081
                resources:
                  requests:
                    cpu: 50m
                    memory: 128Mi
                  limits:
                    memory: 512Mi
                volumeMounts:
                - name: data
                  mountPath: /data
              - name: viewer
                image: nginx:alpine
                ports:
                - containerPort: 8080
                resources:
                  requests:
                    cpu: 10m
                    memory: 32Mi
                  limits:
                    memory: 64Mi
                volumeMounts:
                - name: viewer-html
                  mountPath: /usr/share/nginx/html/index.html
                  subPath: index.html
                - name: viewer-config
                  mountPath: /etc/nginx/conf.d/default.conf
                  subPath: nginx.conf
              volumes:
              - name: data
                persistentVolumeClaim:
                  claimName: openstreetmap-data
              - name: viewer-html
                configMap:
                  name: maplibre-viewer
                  items:
                  - key: index.html
                    path: index.html
              - name: viewer-config
                configMap:
                  name: maplibre-viewer
                  items:
                  - key: nginx.conf
                    path: nginx.conf
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: openstreetmap
          namespace: ${ns}
        spec:
          selector:
            app: openstreetmap
          ports:
          - port: 8080
            targetPort: 8080
        EOF

                create_ingress_route "openstreetmap" "${ns}" "$(hostname maps)" "openstreetmap" "8080"

                print_success "OpenStreetMap" \
                  "URL: https://$(hostname maps)" \
                  "" \
                  "PMTiles data will be downloaded by the openstreetmap-update timer" \
                  "Run 'systemctl start openstreetmap-update' to trigger first download"

                create_marker "${markerFile}"
      '';
    };
  };

  # =========================================
  # openstreetmap-update: Download world PMTiles
  # =========================================
  systemd.services.openstreetmap-update = {
    description = "Update OpenStreetMap PMTiles data";
    after = [
      "openstreetmap-setup.service"
      "nfs-storage-setup.service"
    ];
    wants = [
      "openstreetmap-setup.service"
      "nfs-storage-setup.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "48h";
      ExecStart = pkgs.writeShellScript "openstreetmap-update" ''
        ${k8s.libShSource}
        set -e
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        ${
          if cloudHostPath == null then
            ''
              echo "ERROR: No cloudPaths.openstreetmap configured in NAS config"
              exit 1
            ''
          else
            ''
              DATA_DIR="${cloudHostPath}"
            ''
        }

        if [ ! -d "$DATA_DIR" ]; then
          echo "ERROR: Data directory $DATA_DIR does not exist"
          exit 1
        fi

        # Protomaps daily world build
        BUILDS_URL="https://build.protomaps.com"
        echo "Checking latest world PMTiles build..."

        # Get the latest build date from the builds page
        LATEST=$($CURL -sL "$BUILDS_URL/" | grep -oP '[0-9]{8}\.pmtiles' | sort -V | tail -1)

        if [ -z "$LATEST" ]; then
          echo "Could not determine latest build, using known URL pattern..."
          LATEST_DATE=$(date +%Y%m%d)
          LATEST="$LATEST_DATE.pmtiles"
        fi

        echo "Latest build: $LATEST"

        if [ -f "$DATA_DIR/world.pmtiles" ]; then
          CURRENT_SIZE=$(stat -c%s "$DATA_DIR/world.pmtiles" 2>/dev/null || echo "0")
          echo "Current world.pmtiles: $((CURRENT_SIZE / 1024 / 1024 / 1024)) GB"

          # Check remote size
          REMOTE_SIZE=$($CURL -sI "$BUILDS_URL/$LATEST" | grep -i content-length | awk '{print $2}' | tr -d '\r')
          if [ -n "$REMOTE_SIZE" ] && [ "$CURRENT_SIZE" = "$REMOTE_SIZE" ]; then
            echo "Already up to date, skipping download"
            exit 0
          fi
        fi

        echo "Downloading world PMTiles (~120 GB, this will take a while)..."
        ${pkgs.aria2}/bin/aria2c \
          -x 8 -s 8 -k 50M \
          --continue=true \
          -d "$DATA_DIR" \
          -o "world.pmtiles.tmp" \
          "$BUILDS_URL/$LATEST"

        if [ $? -eq 0 ] && [ -f "$DATA_DIR/world.pmtiles.tmp" ]; then
          mv "$DATA_DIR/world.pmtiles.tmp" "$DATA_DIR/world.pmtiles"
          echo "Download complete"

          echo "Restarting openstreetmap pod..."
          $KUBECTL rollout restart deployment/openstreetmap -n ${ns}
          $KUBECTL rollout status deployment/openstreetmap -n ${ns} --timeout=120s || true
          echo "OpenStreetMap restarted"
        else
          echo "ERROR: Download failed"
          rm -f "$DATA_DIR/world.pmtiles.tmp"
          exit 1
        fi

        echo "OpenStreetMap update complete"
      '';
    };
  };

  # =========================================
  # openstreetmap-update timer: Monthly 1st at 3am
  # =========================================
  systemd.timers.openstreetmap-update = {
    description = "Monthly OpenStreetMap PMTiles update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "2h";
    };
  };
}
