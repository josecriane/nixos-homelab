{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "uptime-kuma";
  markerFile = "/var/lib/uptime-kuma-setup-done";
in
{
  systemd.services.uptime-kuma-setup = {
    description = "Setup Uptime Kuma status monitoring";
    after = [ "k3s-core.target" ];
    requires = [ "k3s-core.target" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "uptime-kuma-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "Uptime Kuma"

                wait_for_k3s
                wait_for_certificate
                setup_namespace "${ns}"

                create_pvc "uptime-kuma-data" "${ns}" "1Gi"

                # Deployment
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: uptime-kuma
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: uptime-kuma
          template:
            metadata:
              labels:
                app: uptime-kuma
            spec:
              containers:
              - name: uptime-kuma
                image: louislam/uptime-kuma:1
                ports:
                - containerPort: 3001
                env:
                - name: TZ
                  value: "${serverConfig.timezone}"
                resources:
                  requests:
                    cpu: 50m
                    memory: 64Mi
                  limits:
                    memory: 256Mi
                volumeMounts:
                - name: data
                  mountPath: /app/data
              volumes:
              - name: data
                persistentVolumeClaim:
                  claimName: uptime-kuma-data
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: uptime-kuma
          namespace: ${ns}
        spec:
          selector:
            app: uptime-kuma
          ports:
          - port: 3001
            targetPort: 3001
        EOF

                wait_for_pod "${ns}" "app=uptime-kuma" 300

                # Wait for database initialization
                sleep 20

                POD=$($KUBECTL get pods -n ${ns} -l app=uptime-kuma -o jsonpath='{.items[0].metadata.name}')

                # Create admin user (reuse existing password if available)
                ADMIN_PASSWORD=$(get_secret_value "${ns}" "uptime-kuma-credentials" "ADMIN_PASSWORD")
                [ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD=$(generate_password 16)
                PASS_HASH=$($KUBECTL exec -n ${ns} $POD -- sh -c "cd /app && node -e \"const bcrypt = require('bcryptjs'); console.log(bcrypt.hashSync('$ADMIN_PASSWORD', 10));\"" 2>/dev/null)

                if [ -n "$PASS_HASH" ]; then
                  # Use REPLACE to ensure password matches credential file even on re-runs
                  $KUBECTL exec -n ${ns} $POD -- sqlite3 /app/data/kuma.db \
                    "INSERT OR REPLACE INTO user (id, username, password, active, timezone) VALUES (1, 'admin', '$PASS_HASH', 1, 'UTC');" 2>/dev/null || true

                  # Restart pod so Uptime Kuma picks up the DB change (it caches user state in memory)
                  $KUBECTL rollout restart deployment/uptime-kuma -n ${ns}
                  $KUBECTL rollout status deployment/uptime-kuma -n ${ns} --timeout=120s 2>/dev/null || true
                  sleep 10

                  # Get new pod name after restart
                  POD=$($KUBECTL get pods -n ${ns} -l app=uptime-kuma -o jsonpath='{.items[0].metadata.name}')
                else
                  echo "WARNING: Could not generate bcrypt hash for Uptime Kuma"
                fi

                # Add monitors (skip if already exist to prevent duplicates on re-runs)
                MONITOR_COUNT=$($KUBECTL exec -n ${ns} $POD -- sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM monitor;" 2>/dev/null || echo "0")
                if [ "$MONITOR_COUNT" = "0" ]; then
                  echo "Inserting monitors..."
                  $KUBECTL exec -n ${ns} $POD -- sqlite3 /app/data/kuma.db "
                    INSERT INTO monitor (name, active, user_id, interval, type, url, method, maxretries, accepted_statuscodes_json) VALUES
                      ('Homarr', 1, 1, 60, 'http', 'https://$(hostname home)', 'GET', 3, '["200-299","300-399"]'),
                      ('Grafana', 1, 1, 60, 'http', 'https://$(hostname grafana)', 'GET', 3, '["200-299","300-399"]'),
                      ('Prometheus', 1, 1, 60, 'http', 'https://$(hostname prometheus)', 'GET', 3, '["200-299","300-399"]'),
                      ('Authentik', 1, 1, 60, 'http', 'https://$(hostname auth)', 'GET', 3, '["200-299","300-399"]'),
                      ('Vaultwarden', 1, 1, 60, 'http', 'https://$(hostname vault)', 'GET', 3, '["200-299","300-399"]'),
                      ('Nextcloud', 1, 1, 60, 'http', 'https://$(hostname cloud)', 'GET', 3, '["200-299","300-399"]'),
                      ('Immich', 1, 1, 60, 'http', 'https://$(hostname photos)', 'GET', 3, '["200-299","300-399"]'),
                      ('Jellyfin', 1, 1, 60, 'http', 'https://$(hostname jellyfin)', 'GET', 3, '["200-299","300-399"]'),
                      ('Jellyseerr', 1, 1, 60, 'http', 'https://$(hostname requests)', 'GET', 3, '["200-299","300-399"]'),
                      ('Prowlarr', 1, 1, 60, 'http', 'https://$(hostname prowlarr)', 'GET', 3, '["200-299","300-399"]'),
                      ('Sonarr', 1, 1, 60, 'http', 'https://$(hostname sonarr)', 'GET', 3, '["200-299","300-399"]'),
                      ('Sonarr ES', 1, 1, 60, 'http', 'https://$(hostname sonarr-es)', 'GET', 3, '["200-299","300-399"]'),
                      ('Radarr', 1, 1, 60, 'http', 'https://$(hostname radarr)', 'GET', 3, '["200-299","300-399"]'),
                      ('Radarr ES', 1, 1, 60, 'http', 'https://$(hostname radarr-es)', 'GET', 3, '["200-299","300-399"]'),
                      ('Lidarr', 1, 1, 60, 'http', 'https://$(hostname lidarr)', 'GET', 3, '["200-299","300-399"]'),
                      ('Bazarr', 1, 1, 60, 'http', 'https://$(hostname bazarr)', 'GET', 3, '["200-299","300-399"]'),
                      ('qBittorrent', 1, 1, 60, 'http', 'https://$(hostname qbit)', 'GET', 3, '["200-299","300-399"]'),
                      ('Bookshelf', 1, 1, 60, 'http', 'https://$(hostname books)', 'GET', 3, '["200-299","300-399"]'),
                      ('Kavita', 1, 1, 60, 'http', 'https://$(hostname kavita)', 'GET', 3, '["200-299","300-399"]'),
                      ('Syncthing', 1, 1, 60, 'http', 'https://$(hostname sync)', 'GET', 3, '["200-299","300-399"]');
                  " 2>/dev/null || true
                  echo "20 monitors inserted"
                else
                  echo "Monitors already exist ($MONITOR_COUNT), skipping"
                fi

                # Save credentials to K8s secret
                store_credentials "${ns}" "uptime-kuma-credentials" \
                  "ADMIN_USER=admin" "ADMIN_PASSWORD=$ADMIN_PASSWORD"

                # IngressRoute (OIDC handles auth)
                create_ingress_route "uptime-kuma" "${ns}" "$(hostname status)" "uptime-kuma" "3001"

                print_success "Uptime Kuma" \
                  "URL: https://$(hostname status)" \
                  "Credentials stored in K8s secret uptime-kuma-credentials" \
                  "20 monitors configured"

                create_marker "${markerFile}"
      '';
    };
  };
}
