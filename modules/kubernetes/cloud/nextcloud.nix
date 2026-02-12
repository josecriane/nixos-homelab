{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "nextcloud";
  markerFile = "/var/lib/nextcloud-setup-done";
  ipParts = lib.splitString "." serverConfig.serverIP;
  lanSubnet = "${builtins.elemAt ipParts 0}.${builtins.elemAt ipParts 1}.${builtins.elemAt ipParts 2}.0/24";

  # Find NAS with cloudPaths.nextcloud for PV fallback creation
  cloudNas = lib.findFirst (
    cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) ? "nextcloud"
  ) null (lib.attrValues (serverConfig.nas or { }));
  cloudHostPath =
    if cloudNas != null then "/mnt/${cloudNas.hostname}/${cloudNas.cloudPaths.nextcloud}" else null;
in
{
  systemd.services.nextcloud-setup = {
    description = "Setup Nextcloud cloud storage";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [ "nfs-storage-setup.service" ];
    # TIER 4: Media
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nextcloud-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "Nextcloud"

                wait_for_k3s
                wait_for_traefik
                wait_for_certificate

                helm_repo_add "nextcloud" "https://nextcloud.github.io/helm/"
                setup_namespace "${ns}"

                # Reuse existing passwords if available (avoid breaking DB on re-runs)
                NEXTCLOUD_ADMIN_PASSWORD=$(get_secret_value "${ns}" "nextcloud" "nextcloud-password")
                if [ -n "$NEXTCLOUD_ADMIN_PASSWORD" ]; then
                  echo "Reusing existing Nextcloud admin password from K8s secret"
                fi

                POSTGRES_PASSWORD=$(get_secret_value "${ns}" "nextcloud-postgresql" "password")
                if [ -n "$POSTGRES_PASSWORD" ]; then
                  echo "Reusing existing PostgreSQL password from K8s secret"
                fi

                # Fallback to credential secret
                if [ -z "$NEXTCLOUD_ADMIN_PASSWORD" ]; then
                  NEXTCLOUD_ADMIN_PASSWORD=$(get_secret_value "${ns}" "nextcloud-local-credentials" "NEXTCLOUD_ADMIN_PASSWORD")
                fi
                if [ -z "$POSTGRES_PASSWORD" ]; then
                  POSTGRES_PASSWORD=$(get_secret_value "${ns}" "nextcloud-local-credentials" "POSTGRES_PASSWORD")
                fi

                # Generate new only on first install
                if [ -z "$NEXTCLOUD_ADMIN_PASSWORD" ]; then
                  NEXTCLOUD_ADMIN_PASSWORD=$(generate_password 16)
                  echo "Generated new Nextcloud admin password"
                fi
                if [ -z "$POSTGRES_PASSWORD" ]; then
                  POSTGRES_PASSWORD=$(generate_hex 16)
                  echo "Generated new PostgreSQL password"
                fi

                # Delete redis StatefulSet before upgrade (immutable spec fields prevent in-place update)
                $KUBECTL delete statefulset -n ${ns} -l app.kubernetes.io/name=redis --ignore-not-found 2>/dev/null || true

                # Wait for NAS PV to exist (created by nfs-storage-setup)
                echo "Waiting for PV nextcloud-data-pv..."
                PV_FOUND=""
                for i in $(seq 1 30); do
                  PV_PHASE=$($KUBECTL get pv nextcloud-data-pv -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                  if [ -n "$PV_PHASE" ]; then
                    echo "PV nextcloud-data-pv found ($PV_PHASE)"
                    PV_FOUND="true"
                    break
                  fi
                  echo "PV not found yet ($i/30)"
                  sleep 10
                done

                ${
                  if cloudHostPath != null then
                    ''
                              # Fallback: create PV if nfs-storage-setup didn't create it
                              if [ -z "$PV_FOUND" ]; then
                                echo "PV not found after waiting, creating as fallback..."
                                mkdir -p "${cloudHostPath}" 2>/dev/null || true
                                cat <<PVFALLBACKEOF | $KUBECTL apply -f -
                      apiVersion: v1
                      kind: PersistentVolume
                      metadata:
                        name: nextcloud-data-pv
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
                      PVFALLBACKEOF
                                echo "PV nextcloud-data-pv created (fallback)"
                              fi
                    ''
                  else
                    ""
                }

                # Create NAS-backed PVC for Nextcloud data
                EXISTING_NC_PVC=$($KUBECTL get pvc nextcloud-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$EXISTING_NC_PVC" = "Bound" ]; then
                  echo "PVC nextcloud-data already Bound, skipping"
                else
                  cat <<NCPVCEOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: nextcloud-data
          namespace: ${ns}
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: nas-storage
          resources:
            requests:
              storage: 1Ti
          volumeName: nextcloud-data-pv
        NCPVCEOF
                  echo "PVC nextcloud-data created (NAS-backed)"
                  for i in $(seq 1 30); do
                    STATUS=$($KUBECTL get pvc nextcloud-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
                    if [ "$STATUS" = "Bound" ]; then
                      echo "PVC nextcloud-data: Bound"
                      break
                    fi
                    echo "  PVC status: $STATUS ($i/30)"
                    sleep 5
                  done
                fi

                # Install Nextcloud
                set +e
                $HELM upgrade --install nextcloud nextcloud/nextcloud \
                  --namespace ${ns} \
                  --set nextcloud.host="$(hostname cloud)" \
                  --set nextcloud.username=admin \
                  --set nextcloud.password="$NEXTCLOUD_ADMIN_PASSWORD" \
                  --set nextcloud.trustedDomains[0]="$(hostname cloud)" \
                  --set 'nextcloud.extraEnv[0].name=OVERWRITEPROTOCOL' \
                  --set 'nextcloud.extraEnv[0].value=https' \
                  --set 'nextcloud.extraEnv[1].name=OVERWRITEHOST' \
                  --set 'nextcloud.extraEnv[1].value='$(hostname cloud) \
                  --set 'nextcloud.extraEnv[2].name=TRUSTED_PROXIES' \
                  --set 'nextcloud.extraEnv[2].value=10.42.0.0/16 10.43.0.0/16 ${lanSubnet}' \
                  --set persistence.enabled=true \
                  --set persistence.size=20Gi \
                  --set 'nextcloud.datadir=/data/nextcloud' \
                  --set persistence.nextcloudData.enabled=true \
                  --set persistence.nextcloudData.existingClaim=nextcloud-data \
                  --set internalDatabase.enabled=false \
                  --set externalDatabase.enabled=true \
                  --set externalDatabase.type=postgresql \
                  --set externalDatabase.host=nextcloud-postgresql \
                  --set externalDatabase.user=nextcloud \
                  --set externalDatabase.password="$POSTGRES_PASSWORD" \
                  --set externalDatabase.database=nextcloud \
                  --set postgresql.enabled=true \
                  --set postgresql.auth.username=nextcloud \
                  --set postgresql.auth.password="$POSTGRES_PASSWORD" \
                  --set postgresql.auth.database=nextcloud \
                  --set postgresql.primary.persistence.enabled=true \
                  --set postgresql.primary.persistence.size=5Gi \
                  --set redis.enabled=true \
                  --set redis.architecture=standalone \
                  --set redis.auth.enabled=false \
                  --set redis.master.persistence.enabled=false \
                  --set 'nextcloud.configs.custom\.config\.php=<?php $CONFIG = array("skeletondirectory" => "");' \
                  --set ingress.enabled=false \
                  --set livenessProbe.enabled=false \
                  --set readinessProbe.enabled=false \
                  --set startupProbe.enabled=true \
                  --set startupProbe.initialDelaySeconds=60 \
                  --set startupProbe.periodSeconds=10 \
                  --set startupProbe.failureThreshold=30 \
                  --timeout 15m 2>&1
                HELM_EXIT=$?
                set -e

                if [ $HELM_EXIT -ne 0 ]; then
                  echo "Helm upgrade failed (exit $HELM_EXIT), retrying with --force..."
                  $HELM upgrade --install nextcloud nextcloud/nextcloud \
                    --namespace ${ns} \
                    --set nextcloud.host="$(hostname cloud)" \
                    --set nextcloud.username=admin \
                    --set nextcloud.password="$NEXTCLOUD_ADMIN_PASSWORD" \
                    --set nextcloud.trustedDomains[0]="$(hostname cloud)" \
                    --set 'nextcloud.extraEnv[0].name=OVERWRITEPROTOCOL' \
                    --set 'nextcloud.extraEnv[0].value=https' \
                    --set 'nextcloud.extraEnv[1].name=OVERWRITEHOST' \
                    --set 'nextcloud.extraEnv[1].value='$(hostname cloud) \
                    --set 'nextcloud.extraEnv[2].name=TRUSTED_PROXIES' \
                    --set 'nextcloud.extraEnv[2].value=10.42.0.0/16 10.43.0.0/16 ${lanSubnet}' \
                    --set persistence.enabled=true \
                    --set persistence.size=20Gi \
                    --set 'nextcloud.datadir=/data/nextcloud' \
                    --set persistence.nextcloudData.enabled=true \
                    --set persistence.nextcloudData.existingClaim=nextcloud-data \
                    --set internalDatabase.enabled=false \
                    --set externalDatabase.enabled=true \
                    --set externalDatabase.type=postgresql \
                    --set externalDatabase.host=nextcloud-postgresql \
                    --set externalDatabase.user=nextcloud \
                    --set externalDatabase.password="$POSTGRES_PASSWORD" \
                    --set externalDatabase.database=nextcloud \
                    --set postgresql.enabled=true \
                    --set postgresql.auth.username=nextcloud \
                    --set postgresql.auth.password="$POSTGRES_PASSWORD" \
                    --set postgresql.auth.database=nextcloud \
                    --set postgresql.primary.persistence.enabled=true \
                    --set postgresql.primary.persistence.size=5Gi \
                    --set redis.enabled=true \
                    --set redis.architecture=standalone \
                    --set redis.auth.enabled=false \
                    --set redis.master.persistence.enabled=false \
                    --set 'nextcloud.configs.custom\.config\.php=<?php $CONFIG = array("skeletondirectory" => "");' \
                    --set ingress.enabled=false \
                    --set livenessProbe.enabled=false \
                    --set readinessProbe.enabled=false \
                    --set startupProbe.enabled=true \
                    --set startupProbe.initialDelaySeconds=60 \
                    --set startupProbe.periodSeconds=10 \
                    --set startupProbe.failureThreshold=30 \
                    --force \
                    --timeout 15m
                fi

                # Wait for pod (Nextcloud takes longer)
                sleep 30
                for i in $(seq 1 60); do
                  READY=$($KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
                  if [ "$READY" = "true" ]; then
                    echo "Nextcloud is ready"
                    break
                  fi
                  echo "Waiting for Nextcloud... ($i/60)"
                  sleep 10
                done

                # Verify Nextcloud is fully installed (auto-install may not trigger if PVC had leftover files)
                NC_POD=$($KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}')
                INSTALLED=$($KUBECTL exec -n ${ns} $NC_POD -c nextcloud -- grep "'installed' => true" /var/www/html/config/config.php 2>/dev/null || echo "")
                if [ -z "$INSTALLED" ]; then
                  echo "Auto-install did not complete, running manual install..."
                  # Read actual password from K8s secret (Helm may generate its own)
                  ACTUAL_PG_PASS=$($KUBECTL get secret nextcloud-postgresql -n ${ns} -o jsonpath='{.data.password}' | base64 -d)
                  $KUBECTL exec -n ${ns} $NC_POD -c nextcloud -- su -s /bin/bash www-data -c \
                    "php occ maintenance:install --database=pgsql --database-host=nextcloud-postgresql --database-name=nextcloud --database-user=nextcloud --database-pass='$ACTUAL_PG_PASS' --admin-user=admin --admin-pass='$NEXTCLOUD_ADMIN_PASSWORD' --data-dir=/data/nextcloud"
                  $KUBECTL exec -n ${ns} $NC_POD -c nextcloud -- su -s /bin/bash www-data -c \
                    "php occ config:system:set trusted_domains 0 --value=$(hostname cloud)"
                  echo "Manual install completed"
                fi

                # IngressRoute with headers middleware
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: traefik.io/v1alpha1
        kind: Middleware
        metadata:
          name: nextcloud-headers
          namespace: ${ns}
        spec:
          headers:
            stsSeconds: 31536000
            stsIncludeSubdomains: true
            stsPreload: true
            customRequestHeaders:
              X-Forwarded-Proto: https
        EOF

                create_ingress_route "nextcloud" "${ns}" "$(hostname cloud)" "nextcloud" "8080" "nextcloud-headers:${ns}"

                # Save credentials to K8s secret
                store_credentials "${ns}" "nextcloud-local-credentials" \
                  "NEXTCLOUD_ADMIN_USER=admin" "NEXTCLOUD_ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD" \
                  "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"

                print_success "Nextcloud" \
                  "URLs:" \
                  "  URL: https://$(hostname cloud)" \
                  "" \
                  "Credentials: admin / $NEXTCLOUD_ADMIN_PASSWORD"

                create_marker "${markerFile}"
      '';
    };
  };

  # OIDC configuration service
  systemd.services.nextcloud-oidc-setup = {
    description = "Configure Nextcloud OIDC with Authentik";
    # After media (SSO already configured)
    after = [
      "k3s-media.target"
      "nextcloud-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [
      "nextcloud-setup.service"
      "authentik-sso-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nextcloud-oidc-setup" ''
        ${k8s.libShSource}
        setup_preamble "/var/lib/nextcloud-oidc-setup-done" "Nextcloud OIDC"

        # Wait for SSO credentials
        wait_for_resource "secret" "${ns}" "authentik-sso-credentials" 300

        if ! $KUBECTL get secret authentik-sso-credentials -n ${ns} &>/dev/null; then
          echo "SSO credentials not available"
          exit 0
        fi

        NEXTCLOUD_CLIENT_ID=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.NEXTCLOUD_CLIENT_ID}' | base64 -d)
        NEXTCLOUD_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.NEXTCLOUD_CLIENT_SECRET}' | base64 -d)

        if [ -z "$NEXTCLOUD_CLIENT_SECRET" ]; then
          echo "No NEXTCLOUD_CLIENT_SECRET found"
          exit 1
        fi

        NC_POD=$($KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}')
        if [ -z "$NC_POD" ]; then
          echo "Nextcloud pod not found"
          exit 1
        fi

        # Wait for pod ready
        for i in $(seq 1 30); do
          READY=$($KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
          if [ "$READY" = "true" ]; then break; fi
          sleep 10
        done

        # Install user_oidc app
        if ! $KUBECTL exec -n ${ns} $NC_POD -- php occ app:install user_oidc 2>/dev/null; then
          OIDC_TMP=$(mktemp -d)
          $CURL -sL -o "$OIDC_TMP/user_oidc.tar.gz" \
            "https://github.com/nextcloud-releases/user_oidc/releases/download/v6.0.1/user_oidc-v6.0.1.tar.gz"
          if [ -f "$OIDC_TMP/user_oidc.tar.gz" ]; then
            ${pkgs.gzip}/bin/gzip -dc "$OIDC_TMP/user_oidc.tar.gz" | ${pkgs.gnutar}/bin/tar -xf - -C "$OIDC_TMP"
            $KUBECTL exec -n ${ns} $NC_POD -- mkdir -p /var/www/html/custom_apps
            $KUBECTL cp "$OIDC_TMP/user_oidc" "${ns}/$NC_POD:/var/www/html/custom_apps/user_oidc"
            rm -rf "$OIDC_TMP"
            $KUBECTL exec -n ${ns} $NC_POD -- php occ app:enable user_oidc 2>/dev/null || true
          fi
        fi

        # Truncate secret (bug in user_oidc)
        TRUNCATED_SECRET=$(echo "$NEXTCLOUD_CLIENT_SECRET" | head -c 64)

        # Configure OIDC provider
        $KUBECTL exec -n ${ns} $NC_POD -- \
          php occ user_oidc:provider Authentik \
            --clientid="$NEXTCLOUD_CLIENT_ID" \
            --clientsecret="$TRUNCATED_SECRET" \
            --discoveryuri="https://$(hostname auth)/application/o/nextcloud/.well-known/openid-configuration" \
            --scope="openid email profile" \
            --unique-uid=1 \
            --mapping-uid="preferred_username" \
            --mapping-display-name="name" \
            --mapping-email="email" 2>/dev/null || true

        # Configure settings
        $KUBECTL exec -n ${ns} $NC_POD -- php occ config:app:set user_oidc auto_provision --value=1 2>/dev/null || true
        $KUBECTL exec -n ${ns} $NC_POD -- php occ config:app:set user_oidc allow_multiple_user_backends --value=0 2>/dev/null || true
        $KUBECTL exec -n ${ns} $NC_POD -- php occ config:system:set allow_local_remote_servers --value=true --type=boolean 2>/dev/null || true

        print_success "Nextcloud OIDC" \
          "URLs:" \
          "  URL: https://$(hostname cloud)" \
          "" \
          "Login: Click 'Log in with Authentik'"

        create_marker "/var/lib/nextcloud-oidc-setup-done"
      '';
    };
  };
}
