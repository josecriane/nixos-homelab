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
  domain = "${serverConfig.subdomain}.${serverConfig.domain}";
  markerFile = "/var/lib/jellyseerr-setup-done";
  oidcMarkerFile = "/var/lib/jellyseerr-oidc-config-done";
in
{
  # ============================================
  # SERVICE 1: Jellyseerr deployment (k3s-media tier)
  # ============================================
  systemd.services.jellyseerr-setup = {
    description = "Setup Jellyseerr media requests";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
      "jellyfin-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "nfs-storage-setup.service"
      "jellyfin-setup.service"
    ];
    # TIER 4: Media
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "jellyseerr-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "Jellyseerr"

                wait_for_k3s
                wait_for_resource "namespace" "default" "${ns}" 150

                # PVC
                create_pvc "jellyseerr-config" "${ns}" "1Gi"

                # Deployment with two init containers:
                # 1. validate-settings: restores from backup if settings.json is corrupt
                # 2. oidc-config: merges OIDC config from optional ConfigMap
                cat <<'EOFYAML' | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: jellyseerr
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: jellyseerr
          template:
            metadata:
              labels:
                app: jellyseerr
            spec:
              initContainers:
              - name: validate-settings
                image: busybox:latest
                command: ['sh', '-c']
                args:
                - |
                  SETTINGS=/app/config/settings.json
                  BACKUP=/app/config/settings.old.json
                  if [ -f "$SETTINGS" ] && tail -c 10 "$SETTINGS" | grep -q "}" && [ $(wc -c < "$SETTINGS") -gt 100 ]; then
                    echo "settings.json OK ($(wc -c < "$SETTINGS") bytes)"
                    cp "$SETTINGS" "$BACKUP"
                  elif [ -f "$BACKUP" ] && tail -c 10 "$BACKUP" | grep -q "}" && [ $(wc -c < "$BACKUP") -gt 100 ]; then
                    echo "Restoring from settings.old.json"
                    cp "$BACKUP" "$SETTINGS"
                  else
                    echo "No valid settings found, Jellyseerr will create defaults"
                    rm -f "$SETTINGS"
                  fi
                volumeMounts:
                - name: config
                  mountPath: /app/config
              - name: oidc-config
                image: alpine:latest
                command: ['sh', '-c']
                args:
                - |
                  apk add --no-cache jq > /dev/null 2>&1
                  SETTINGS=/app/config/settings.json
                  OIDC_FILE=/oidc/config.json
                  if [ -f "$OIDC_FILE" ] && [ -f "$SETTINGS" ]; then
                    echo "Merging OIDC config into settings.json..."
                    jq -s '.[0] * .[1]' "$SETTINGS" "$OIDC_FILE" > "$SETTINGS.tmp"
                    if [ -s "$SETTINGS.tmp" ]; then
                      mv "$SETTINGS.tmp" "$SETTINGS"
                      echo "OIDC config merged successfully"
                    else
                      echo "WARN: merge produced empty file, keeping original"
                      rm -f "$SETTINGS.tmp"
                    fi
                  elif [ -f "$OIDC_FILE" ]; then
                    echo "No settings.json yet, OIDC will be merged on next restart"
                  else
                    echo "No OIDC ConfigMap mounted, skipping"
                  fi
                volumeMounts:
                - name: config
                  mountPath: /app/config
                - name: oidc
                  mountPath: /oidc
                  readOnly: true
              containers:
              - name: jellyseerr
                image: fallenbagel/jellyseerr:preview-OIDC
                ports:
                - containerPort: 5055
                env:
                - name: TZ
                  value: "UTC"
                - name: TRUST_PROXY
                  value: "true"
                resources:
                  requests:
                    cpu: 50m
                    memory: 128Mi
                  limits:
                    memory: 512Mi
                volumeMounts:
                - name: config
                  mountPath: /app/config
              volumes:
              - name: config
                persistentVolumeClaim:
                  claimName: jellyseerr-config
              - name: oidc
                configMap:
                  name: jellyseerr-oidc
                  optional: true
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: jellyseerr
          namespace: ${ns}
        spec:
          selector:
            app: jellyseerr
          ports:
          - port: 5055
            targetPort: 5055
        EOFYAML

                wait_for_pod "${ns}" "app=jellyseerr" 180

                # IngressRoute
                create_ingress_route "jellyseerr" "${ns}" "$(hostname requests)" "jellyseerr" "5055"

                print_success "Jellyseerr" \
                  "URLs:" \
                  "  URL: https://$(hostname requests)" \
                  "" \
                  "Automatically configured by jellyfin-integration" \
                  "OIDC will be configured automatically if Authentik SSO is enabled"

                create_marker "${markerFile}"
      '';
    };
  };

  # ============================================
  # SERVICE 2: Jellyseerr OIDC config (k3s-extras tier)
  # ============================================
  systemd.services.jellyseerr-oidc-config = {
    description = "Configure Jellyseerr OIDC via ConfigMap";
    after = [
      "k3s-media.target"
      "jellyseerr-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [
      "jellyseerr-setup.service"
      "authentik-sso-setup.service"
    ];
    # TIER 5: Extras
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "jellyseerr-oidc-config" ''
                ${k8s.libShSource}
                setup_preamble "${oidcMarkerFile}" "Jellyseerr OIDC"

                wait_for_k3s

                # Check if SSO credentials exist
                if ! $KUBECTL get secret authentik-sso-credentials -n ${ns} &>/dev/null; then
                  echo "No SSO credentials found, skipping OIDC configuration"
                  touch ${oidcMarkerFile}
                  exit 0
                fi

                JELLYSEERR_CLIENT_ID=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.JELLYSEERR_CLIENT_ID}' | base64 -d 2>/dev/null || echo "")
                JELLYSEERR_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.JELLYSEERR_CLIENT_SECRET}' | base64 -d 2>/dev/null || echo "")

                if [ -z "$JELLYSEERR_CLIENT_SECRET" ]; then
                  echo "No Jellyseerr client secret in SSO credentials, skipping"
                  touch ${oidcMarkerFile}
                  exit 0
                fi

                echo "Creating jellyseerr-oidc ConfigMap..."

                # Build OIDC config JSON with actual credentials
                OIDC_JSON=$(cat <<EOFJSON
        {
          "main": {"oidcLogin": true, "applicationUrl": "https://$(hostname requests)"},
          "network": {"trustProxy": true},
          "oidc": {
            "providers": [{
              "name": "authentik",
              "slug": "authentik",
              "clientId": "$JELLYSEERR_CLIENT_ID",
              "clientSecret": "$JELLYSEERR_CLIENT_SECRET",
              "issuerUrl": "https://auth.${domain}/application/o/jellyseerr/",
              "newUserLogin": true
            }]
          }
        }
        EOFJSON
                )

                # Create/update ConfigMap
                $KUBECTL create configmap jellyseerr-oidc \
                  --namespace=${ns} \
                  --from-literal=config.json="$OIDC_JSON" \
                  --dry-run=client -o yaml | $KUBECTL apply -f -

                echo "ConfigMap jellyseerr-oidc created"

                # Bounce Jellyseerr to trigger init container merge
                echo "Restarting Jellyseerr to apply OIDC config..."
                $KUBECTL scale deploy -n ${ns} jellyseerr --replicas=0
                for i in $(seq 1 30); do
                  REMAINING=$($KUBECTL get pods -n ${ns} -l app=jellyseerr --no-headers 2>/dev/null | wc -l)
                  [ "$REMAINING" -eq 0 ] && break
                  sleep 2
                done
                sleep 2

                $KUBECTL scale deploy -n ${ns} jellyseerr --replicas=1
                $KUBECTL rollout status deployment/jellyseerr -n ${ns} --timeout=120s 2>/dev/null || true

                # Save Jellyseerr credentials to K8s secret
                JELLYSEERR_API_KEY=""
                JSEERR_SETTINGS=$(find /var/lib/rancher/k3s/storage -name "settings.json" -path "*jellyseerr*" 2>/dev/null | head -1)
                if [ -n "$JSEERR_SETTINGS" ] && [ -f "$JSEERR_SETTINGS" ]; then
                  JELLYSEERR_API_KEY=$($JQ -r '.main.apiKey // empty' "$JSEERR_SETTINGS" 2>/dev/null)
                fi

                store_credentials "${ns}" "jellyseerr-credentials" \
                  "API_KEY=$JELLYSEERR_API_KEY" "URL=https://$(hostname requests)"

                print_success "Jellyseerr OIDC" \
                  "URLs:" \
                  "  URL: https://$(hostname requests)" \
                  "" \
                  "OIDC configured via ConfigMap + init container merge"

                create_marker "${oidcMarkerFile}"
      '';
    };
  };
}
