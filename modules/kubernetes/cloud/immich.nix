{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "immich";
  markerFile = "/var/lib/immich-setup-done";

  # Find NAS with cloudPaths.immich for PV fallback creation
  cloudNas = lib.findFirst (cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) ? "immich") null (
    lib.attrValues (serverConfig.nas or { })
  );
  cloudHostPath =
    if cloudNas != null then "/mnt/${cloudNas.hostname}/${cloudNas.cloudPaths.immich}" else null;
in
{
  systemd.services.immich-setup = {
    description = "Setup Immich photo management";
    after = [ "k3s-core.target" ];
    requires = [ "k3s-core.target" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "immich-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "Immich"

                wait_for_k3s
                wait_for_certificate
                setup_namespace "${ns}"

                # Use existing password or generate new one
                EXISTING_PASS=$($KUBECTL get secret immich-secrets -n ${ns} -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
                if [ -n "$EXISTING_PASS" ]; then
                  DB_PASSWORD="$EXISTING_PASS"
                  echo "Using existing password from immich-secrets"
                else
                  DB_PASSWORD=$(generate_hex 16)
                  echo "Generated new password for immich"
                fi

                # Create secrets
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: immich-secrets
          namespace: ${ns}
        type: Opaque
        stringData:
          DB_PASSWORD: "$DB_PASSWORD"
          DB_HOSTNAME: "immich-postgres"
          DB_USERNAME: "immich"
          DB_DATABASE_NAME: "immich"
          REDIS_HOSTNAME: "immich-redis"
        EOF

                # Ensure NAS PV exists for photo library
                PV_PHASE=$($KUBECTL get pv immich-data-pv -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ -n "$PV_PHASE" ]; then
                  echo "PV immich-data-pv found ($PV_PHASE)"
                else
                  ${
                    if cloudHostPath != null then
                      ''
                                  echo "PV immich-data-pv not found, creating..."
                                  mkdir -p "${cloudHostPath}" 2>/dev/null || true
                                  cat <<PVFALLBACKEOF | $KUBECTL apply -f -
                        apiVersion: v1
                        kind: PersistentVolume
                        metadata:
                          name: immich-data-pv
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
                                  echo "PV immich-data-pv created (fallback)"
                      ''
                    else
                      ''
                        echo "WARNING: PV immich-data-pv not found and no cloudPaths configured"
                      ''
                  }
                fi

                # NAS-backed PVC for photo library
                EXISTING_LIB_PVC=$($KUBECTL get pvc immich-library -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$EXISTING_LIB_PVC" = "Bound" ]; then
                  echo "PVC immich-library already Bound, skipping"
                else
                  cat <<LIBPVCEOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: immich-library
          namespace: ${ns}
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: nas-storage
          resources:
            requests:
              storage: 1Ti
          volumeName: immich-data-pv
        LIBPVCEOF
                  echo "PVC immich-library created (NAS-backed)"
                  for i in $(seq 1 30); do
                    STATUS=$($KUBECTL get pvc immich-library -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
                    if [ "$STATUS" = "Bound" ]; then
                      echo "PVC immich-library: Bound"
                      break
                    fi
                    echo "  PVC status: $STATUS ($i/30)"
                    sleep 5
                  done
                fi

                # Local PVCs for postgres and ML cache (good I/O needed)
                create_pvc "immich-postgres" "${ns}" "5Gi"
                create_pvc "immich-ml-cache" "${ns}" "10Gi"

                # PostgreSQL with pgvector
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: immich-postgres
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: immich-postgres
          template:
            metadata:
              labels:
                app: immich-postgres
            spec:
              containers:
              - name: postgres
                image: tensorchord/pgvecto-rs:pg16-v0.2.1
                env:
                - name: POSTGRES_USER
                  value: "immich"
                - name: POSTGRES_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: immich-secrets
                      key: DB_PASSWORD
                - name: POSTGRES_DB
                  value: "immich"
                ports:
                - containerPort: 5432
                resources:
                  requests:
                    cpu: 100m
                    memory: 256Mi
                  limits:
                    memory: 1Gi
                volumeMounts:
                - name: data
                  mountPath: /var/lib/postgresql/data
              volumes:
              - name: data
                persistentVolumeClaim:
                  claimName: immich-postgres
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: immich-postgres
          namespace: ${ns}
        spec:
          selector:
            app: immich-postgres
          ports:
          - port: 5432
            targetPort: 5432
        EOF

                # Redis
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: immich-redis
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: immich-redis
          template:
            metadata:
              labels:
                app: immich-redis
            spec:
              containers:
              - name: redis
                image: redis:7-alpine
                ports:
                - containerPort: 6379
                resources:
                  requests:
                    cpu: 50m
                    memory: 64Mi
                  limits:
                    memory: 256Mi
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: immich-redis
          namespace: ${ns}
        spec:
          selector:
            app: immich-redis
          ports:
          - port: 6379
            targetPort: 6379
        EOF

                sleep 30

                # Immich Server
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: immich-server
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: immich-server
          template:
            metadata:
              labels:
                app: immich-server
            spec:
              containers:
              - name: immich-server
                image: ghcr.io/immich-app/immich-server:v2.5.6
                env:
                - name: DB_HOSTNAME
                  valueFrom:
                    secretKeyRef:
                      name: immich-secrets
                      key: DB_HOSTNAME
                - name: DB_USERNAME
                  valueFrom:
                    secretKeyRef:
                      name: immich-secrets
                      key: DB_USERNAME
                - name: DB_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: immich-secrets
                      key: DB_PASSWORD
                - name: DB_DATABASE_NAME
                  valueFrom:
                    secretKeyRef:
                      name: immich-secrets
                      key: DB_DATABASE_NAME
                - name: REDIS_HOSTNAME
                  valueFrom:
                    secretKeyRef:
                      name: immich-secrets
                      key: REDIS_HOSTNAME
                - name: IMMICH_MACHINE_LEARNING_URL
                  value: "http://immich-ml:3003"
                - name: TZ
                  value: "${serverConfig.timezone}"
                ports:
                - containerPort: 2283
                resources:
                  requests:
                    cpu: 100m
                    memory: 256Mi
                  limits:
                    memory: 2Gi
                volumeMounts:
                - name: library
                  mountPath: /usr/src/app/upload
              volumes:
              - name: library
                persistentVolumeClaim:
                  claimName: immich-library
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: immich-server
          namespace: ${ns}
        spec:
          selector:
            app: immich-server
          ports:
          - port: 2283
            targetPort: 2283
        EOF

                # Immich Machine Learning
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: immich-ml
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: immich-ml
          template:
            metadata:
              labels:
                app: immich-ml
            spec:
              containers:
              - name: immich-ml
                image: ghcr.io/immich-app/immich-machine-learning:v2.5.6
                env:
                - name: TZ
                  value: "${serverConfig.timezone}"
                ports:
                - containerPort: 3003
                resources:
                  requests:
                    cpu: 200m
                    memory: 512Mi
                  limits:
                    memory: 3Gi
                volumeMounts:
                - name: cache
                  mountPath: /cache
              volumes:
              - name: cache
                persistentVolumeClaim:
                  claimName: immich-ml-cache
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: immich-ml
          namespace: ${ns}
        spec:
          selector:
            app: immich-ml
          ports:
          - port: 3003
            targetPort: 3003
        EOF

                # Wait for server
                sleep 60
                for i in $(seq 1 60); do
                  READY=$($KUBECTL get pods -n ${ns} -l app=immich-server -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
                  if [ "$READY" = "true" ]; then
                    echo "Immich server ready"
                    break
                  fi
                  echo "Waiting for Immich... ($i/60)"
                  sleep 10
                done

                create_ingress_route "immich" "${ns}" "$(hostname photos)" "immich-server" "2283"

                # Save credentials to K8s secret
                store_credentials "${ns}" "immich-local-credentials" \
                  "DB_PASSWORD=$DB_PASSWORD"

                print_success "Immich" \
                  "URLs:" \
                  "  URL: https://$(hostname photos)" \
                  "" \
                  "Create admin account on first access"

                create_marker "${markerFile}"
      '';
    };
  };

  # OAuth configuration service
  systemd.services.immich-oauth-setup = {
    description = "Configure Immich OAuth with Authentik";
    after = [
      "k3s-core.target"
      "immich-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "immich-setup.service"
      "authentik-sso-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "immich-oauth-setup" ''
        ${k8s.libShSource}
        setup_preamble "/var/lib/immich-oauth-setup-done" "Immich OAuth"

        # Wait for SSO credentials
        wait_for_resource "secret" "${ns}" "authentik-sso-credentials" 300

        if ! $KUBECTL get secret authentik-sso-credentials -n ${ns} &>/dev/null; then
          echo "SSO credentials not available"
          exit 0
        fi

        OAUTH_CLIENT_ID=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.IMMICH_CLIENT_ID}' | base64 -d)
        OAUTH_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.IMMICH_CLIENT_SECRET}' | base64 -d)

        if [ -z "$OAUTH_CLIENT_SECRET" ]; then
          echo "No IMMICH_CLIENT_SECRET found"
          exit 1
        fi

        # Wait for Immich
        for i in $(seq 1 30); do
          READY=$($KUBECTL get pods -n ${ns} -l app=immich-server -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
          if [ "$READY" = "true" ]; then break; fi
          sleep 10
        done
        sleep 30

        # Check if we already have credentials
        ADMIN_EMAIL=$(get_secret_value "${ns}" "immich-local-credentials" "USER")
        ADMIN_PASSWORD=$(get_secret_value "${ns}" "immich-local-credentials" "PASSWORD")
        [ -z "$ADMIN_EMAIL" ] && ADMIN_EMAIL="admin@${serverConfig.domain}"

        # Try to create admin user (will fail if already exists, that's OK)
        if [ -z "$ADMIN_PASSWORD" ]; then
          ADMIN_PASSWORD=$($OPENSSL rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
        fi
        SIGNUP_RESULT=$($KUBECTL exec -n ${ns} deploy/immich-server -- \
          curl -s -X POST "http://localhost:2283/api/auth/admin-sign-up" \
          -H "Content-Type: application/json" \
          -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\",\"name\":\"Admin\"}" 2>/dev/null || echo "{}")

        if echo "$SIGNUP_RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
          echo "Admin created"
          store_credentials "${ns}" "immich-local-credentials" \
            "USER=$ADMIN_EMAIL" "PASSWORD=$ADMIN_PASSWORD" \
            "URL=https://$(hostname photos)" "DB_PASSWORD=$(get_secret_value "${ns}" "immich-secrets" "DB_PASSWORD")"
        fi

        # Login to get token — try saved password first
        LOGIN_RESPONSE=$($KUBECTL exec -n ${ns} deploy/immich-server -- \
          curl -s -X POST "http://localhost:2283/api/auth/login" \
          -H "Content-Type: application/json" \
          -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "{}")
        ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | $JQ -r '.accessToken // empty' 2>/dev/null || echo "")

        # If login fails, reset admin password via CLI and retry
        if [ -z "$ACCESS_TOKEN" ]; then
          echo "Login failed, resetting admin password..."
          ADMIN_PASSWORD=$($OPENSSL rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
          echo "$ADMIN_PASSWORD" | $KUBECTL exec -i -n ${ns} deploy/immich-server -- \
            immich-admin reset-admin-password 2>/dev/null || true
          sleep 3

          store_credentials "${ns}" "immich-local-credentials" \
            "USER=$ADMIN_EMAIL" "PASSWORD=$ADMIN_PASSWORD" \
            "URL=https://$(hostname photos)" "DB_PASSWORD=$(get_secret_value "${ns}" "immich-secrets" "DB_PASSWORD")"

          LOGIN_RESPONSE=$($KUBECTL exec -n ${ns} deploy/immich-server -- \
            curl -s -X POST "http://localhost:2283/api/auth/login" \
            -H "Content-Type: application/json" \
            -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "{}")
        fi
        ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | $JQ -r '.accessToken // empty' 2>/dev/null || echo "")

        if [ -n "$ACCESS_TOKEN" ]; then
          # Get current config
          CONFIG_RAW=$($KUBECTL exec -n ${ns} deploy/immich-server -- \
            curl -s "http://localhost:2283/api/system-config" \
            -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null || echo "{}")
          IMMICH_CONFIG_TMP=$(mktemp)
          IMMICH_CONFIG_NEW_TMP=$(mktemp)
          echo "$CONFIG_RAW" | $JQ '.' > "$IMMICH_CONFIG_TMP" 2>/dev/null

          # Modify OAuth
          $JQ ".oauth.enabled = true |
            .oauth.issuerUrl = \"https://$(hostname auth)/application/o/immich/\" |
            .oauth.clientId = \"$OAUTH_CLIENT_ID\" |
            .oauth.clientSecret = \"$OAUTH_CLIENT_SECRET\" |
            .oauth.buttonText = \"Login with Authentik\" |
            .oauth.autoRegister = true |
            .oauth.scope = \"openid email profile\"" "$IMMICH_CONFIG_TMP" > "$IMMICH_CONFIG_NEW_TMP"

          # Apply config
          $KUBECTL exec -n ${ns} deploy/immich-server -- \
            curl -s -X PUT "http://localhost:2283/api/system-config" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -d "$(cat "$IMMICH_CONFIG_NEW_TMP")" 2>/dev/null

          rm -f "$IMMICH_CONFIG_TMP" "$IMMICH_CONFIG_NEW_TMP"
          echo "OAuth configured"
        else
          echo "Could not obtain token to configure OAuth"
        fi

        print_success "Immich OAuth" \
          "URLs:" \
          "  URL: https://$(hostname photos)" \
          "" \
          "Login: Click 'Login with Authentik'"

        create_marker "/var/lib/immich-oauth-setup-done"
      '';
    };
  };
}
