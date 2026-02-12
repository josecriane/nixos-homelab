# Kiwix - Offline Wikipedia + iFixit
# Serves ZIM files via kiwix-serve, auto-updates weekly via systemd timer
# ZIM files stored on NAS (cloudPaths.kiwix), served via NFS-backed PV
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "kiwix";
  markerFile = "/var/lib/kiwix-setup-done";

  aria2c = "${pkgs.aria2}/bin/aria2c";

  # Find NAS with cloudPaths.kiwix
  cloudNas = lib.findFirst (cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) ? "kiwix") null (
    lib.attrValues (serverConfig.nas or { })
  );
  cloudHostPath =
    if cloudNas != null then "/mnt/${cloudNas.hostname}/${cloudNas.cloudPaths.kiwix}" else null;
in
{
  # =========================================
  # kiwix-setup: Deploy kiwix-serve + ingress
  # =========================================
  systemd.services.kiwix-setup = {
    description = "Setup Kiwix offline knowledge server";
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
      ExecStart = pkgs.writeShellScript "kiwix-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "Kiwix"

                wait_for_k3s
                wait_for_certificate
                setup_namespace "${ns}"

                # Ensure NAS PV exists
                PV_PHASE=$($KUBECTL get pv kiwix-data-pv -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ -n "$PV_PHASE" ]; then
                  echo "PV kiwix-data-pv found ($PV_PHASE)"
                else
                  ${
                    if cloudHostPath != null then
                      ''
                                  echo "PV kiwix-data-pv not found, creating..."
                                  mkdir -p "${cloudHostPath}" 2>/dev/null || true
                                  cat <<PVEOF | $KUBECTL apply -f -
                        apiVersion: v1
                        kind: PersistentVolume
                        metadata:
                          name: kiwix-data-pv
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
                                  echo "PV kiwix-data-pv created"
                      ''
                    else
                      ''
                        echo "WARNING: PV kiwix-data-pv not found and no cloudPaths.kiwix configured"
                      ''
                  }
                fi

                # NAS-backed PVC
                EXISTING_PVC=$($KUBECTL get pvc kiwix-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$EXISTING_PVC" = "Bound" ]; then
                  echo "PVC kiwix-data already Bound, skipping"
                else
                  cat <<PVCEOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: kiwix-data
          namespace: ${ns}
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: nas-storage
          resources:
            requests:
              storage: 1Ti
          volumeName: kiwix-data-pv
        PVCEOF
                  echo "PVC kiwix-data created"
                  for i in $(seq 1 30); do
                    STATUS=$($KUBECTL get pvc kiwix-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
                    if [ "$STATUS" = "Bound" ]; then
                      echo "PVC kiwix-data: Bound"
                      break
                    fi
                    echo "  PVC status: $STATUS ($i/30)"
                    sleep 5
                  done
                fi

                # Deploy kiwix-serve
                cat <<'EOF' | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: kiwix-serve
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: kiwix-serve
          template:
            metadata:
              labels:
                app: kiwix-serve
            spec:
              containers:
              - name: kiwix-serve
                image: ghcr.io/kiwix/kiwix-serve:3.7.0
                command: ["sh", "-c"]
                args:
                - |
                  while ! ls /data/*.zim >/dev/null 2>&1; do
                    echo "Waiting for ZIM files..."
                    sleep 30
                  done
                  exec kiwix-serve --port 8080 /data/*.zim
                ports:
                - containerPort: 8080
                resources:
                  requests:
                    cpu: 100m
                    memory: 256Mi
                  limits:
                    memory: 1Gi
                volumeMounts:
                - name: data
                  mountPath: /data
              volumes:
              - name: data
                persistentVolumeClaim:
                  claimName: kiwix-data
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: kiwix-serve
          namespace: ${ns}
        spec:
          selector:
            app: kiwix-serve
          ports:
          - port: 8080
            targetPort: 8080
        EOF

                create_ingress_route "kiwix" "${ns}" "$(hostname wiki)" "kiwix-serve" "8080"

                print_success "Kiwix" \
                  "URL: https://$(hostname wiki)" \
                  "" \
                  "ZIM files will be downloaded by the kiwix-update timer" \
                  "Run 'systemctl start kiwix-update' to trigger first download"

                create_marker "${markerFile}"
      '';
    };
  };

  # =========================================
  # kiwix-update: Download/update ZIM files
  # =========================================
  systemd.services.kiwix-update = {
    description = "Update Kiwix ZIM files";
    after = [
      "kiwix-setup.service"
      "nfs-storage-setup.service"
    ];
    wants = [
      "kiwix-setup.service"
      "nfs-storage-setup.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "24h";
      ExecStart = pkgs.writeShellScript "kiwix-update" ''
        ${k8s.libShSource}
        set -e
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        ${
          if cloudHostPath == null then
            ''
              echo "ERROR: No cloudPaths.kiwix configured in NAS config"
              exit 1
            ''
          else
            ''
              ZIM_DIR="${cloudHostPath}"
            ''
        }

        if [ ! -d "$ZIM_DIR" ]; then
          echo "ERROR: ZIM directory $ZIM_DIR does not exist"
          exit 1
        fi

        DOWNLOADED=false

        download_latest_zim() {
          local category="$1"
          local pattern="$2"

          echo "Checking $category/$pattern..."

          # Get directory listing
          local listing
          listing=$($CURL -s "https://download.kiwix.org/zim/$category/")
          if [ -z "$listing" ]; then
            echo "  ERROR: Could not fetch listing for $category"
            return 1
          fi

          # Find latest ZIM matching pattern
          local latest
          latest=$(echo "$listing" | grep -oP "''${pattern}_[0-9-]+\.zim(?=\")" | sort -V | tail -1)
          if [ -z "$latest" ]; then
            echo "  ERROR: No ZIM found matching $pattern"
            return 1
          fi

          echo "  Latest: $latest"

          # Check if already downloaded
          if [ -f "$ZIM_DIR/$latest" ]; then
            echo "  Already up to date, skipping"
            return 0
          fi

          echo "  Downloading $latest..."
          ${aria2c} -x 8 -c -d "$ZIM_DIR" \
            "https://download.kiwix.org/zim/$category/$latest"

          if [ $? -eq 0 ] && [ -f "$ZIM_DIR/$latest" ]; then
            echo "  Download complete"
            DOWNLOADED=true

            # Remove old versions of same pattern
            for old_file in "$ZIM_DIR"/''${pattern}_*.zim; do
              if [ -f "$old_file" ] && [ "$(basename "$old_file")" != "$latest" ]; then
                echo "  Removing old version: $(basename "$old_file")"
                rm -f "$old_file"
              fi
            done
          else
            echo "  ERROR: Download failed for $latest"
            return 1
          fi
        }

        download_latest_zim "wikipedia" "wikipedia_en_all_maxi"
        download_latest_zim "wikipedia" "wikipedia_es_all_maxi"
        download_latest_zim "ifixit" "ifixit_en_all"
        download_latest_zim "ifixit" "ifixit_es_all"

        if [ "$DOWNLOADED" = "true" ]; then
          echo "New ZIM files downloaded, restarting kiwix-serve..."
          $KUBECTL rollout restart deployment/kiwix-serve -n ${ns}
          $KUBECTL rollout status deployment/kiwix-serve -n ${ns} --timeout=120s || true
          echo "kiwix-serve restarted"
        else
          echo "No new ZIM files, no restart needed"
        fi

        echo "Kiwix update complete"
      '';
    };
  };

  # =========================================
  # kiwix-update timer: Weekly Monday 4am
  # =========================================
  systemd.timers.kiwix-update = {
    description = "Weekly Kiwix ZIM update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon *-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
