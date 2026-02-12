{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "homarr";
  markerFile = "/var/lib/homarr-setup-done";
  configMarkerFile = "/var/lib/homarr-config-done";

  homarrCreateApiKeyScript = ./scripts/homarr-create-api-key.js;
  homarrPopulateBoardScript = ./scripts/homarr-populate-board.js;
  homarrPopulateInfraBoardScript = ./scripts/homarr-populate-infra-board.js;
in
{
  # ============================================
  # SERVICE 1: homarr-setup (Helm + IngressRoute)
  # ============================================
  systemd.services.homarr-setup = {
    description = "Setup Homarr dashboard";
    after = [ "k3s-storage.target" ];
    requires = [ "k3s-storage.target" ];
    # TIER 3: Core
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "homarr-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "Homarr"

                wait_for_k3s
                wait_for_traefik
                wait_for_certificate

                # Reuse existing encryption key or generate new one
                ENCRYPTION_KEY=$(get_secret_value "${ns}" "homarr-credentials" "ENCRYPTION_KEY")
                if [ -z "$ENCRYPTION_KEY" ]; then
                  ENCRYPTION_KEY=$($OPENSSL rand -hex 32)
                  echo "Generated Homarr encryption key"
                fi

                helm_repo_add "homarr-labs" "https://homarr-labs.github.io/charts/"
                setup_namespace "${ns}"

                # Create db-encryption secret (required by the Helm chart)
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: db-encryption
          namespace: ${ns}
        type: Opaque
        stringData:
          db-encryption-key: "$ENCRYPTION_KEY"
        EOF

                # Install Homarr via Helm
                $HELM upgrade --install homarr homarr-labs/homarr -n ${ns} \
                  --set "env.AUTH_PROVIDERS=credentials" \
                  --set "env.TZ=${serverConfig.timezone}" \
                  --set "env.SECRET_ENCRYPTION_KEY=$ENCRYPTION_KEY" \
                  --set resources.requests.cpu=50m \
                  --set resources.requests.memory=256Mi \
                  --set resources.limits.memory=1Gi \
                  --set persistence.homarrDatabase.enabled=true \
                  --set persistence.homarrDatabase.size=2Gi \
                  --wait --timeout 10m

                wait_for_deployment "${ns}" "homarr" 300

                create_ingress_route "homarr" "${ns}" "$(hostname home)" "homarr" "7575"

                print_success "Homarr" \
                  "URL: https://$(hostname home)"

                create_marker "${markerFile}"
      '';
    };
  };

  # ============================================
  # SERVICE 2: homarr-config (API configuration)
  # ============================================
  systemd.services.homarr-config = {
    description = "Configure Homarr dashboard via API (apps, integrations, OIDC)";
    after = [
      "k3s-media.target"
      "homarr-setup.service"
      "arr-secrets-setup.service"
      "arr-credentials-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [
      "homarr-setup.service"
      "arr-secrets-setup.service"
      "arr-credentials-setup.service"
      "authentik-sso-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "homarr-config" ''
        ${k8s.libShSource}
        setup_preamble "${configMarkerFile}" "Homarr Config"

        # ============================================
        # A) ADMIN USER + API KEY
        # ============================================

        # Reuse existing admin password or generate new one (must meet Homarr complexity: upper+lower+digit+special)
        ADMIN_PASSWORD=$(get_secret_value "${ns}" "homarr-credentials" "ADMIN_PASSWORD")
        if [ -z "$ADMIN_PASSWORD" ]; then
          RAND=$($OPENSSL rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 12)
          ADMIN_PASSWORD="H0m@rr!''${RAND}"
          echo "Generated Homarr admin password"
        fi

        # Wait for Homarr deployment and service to exist
        echo "Waiting for Homarr deployment..."
        for i in $(seq 1 60); do
          if $KUBECTL get svc homarr -n ${ns} &>/dev/null && \
             $KUBECTL get deploy homarr -n ${ns} &>/dev/null; then
            break
          fi
          echo "Waiting for homarr service... ($i/60)"
          sleep 5
        done
        $KUBECTL rollout status deployment/homarr -n ${ns} --timeout=300s 2>/dev/null || true

        # Port-forward to Homarr (with retry)
        PF_PID=""
        cleanup() { [ -n "$PF_PID" ] && kill $PF_PID 2>/dev/null || true; }
        trap cleanup EXIT

        start_port_forward() {
          [ -n "$PF_PID" ] && kill $PF_PID 2>/dev/null || true
          sleep 1
          $KUBECTL port-forward -n ${ns} svc/homarr 17575:7575 &
          PF_PID=$!
          sleep 3
        }

        start_port_forward

        # Wait for API ready (retry port-forward if it dies)
        echo "Waiting for Homarr API..."
        API_READY=false
        for i in $(seq 1 60); do
          if $CURL -sf http://localhost:17575/api/health/live &>/dev/null; then
            echo "Homarr API available"
            API_READY=true
            break
          fi
          # Check if port-forward process died, restart it
          if ! kill -0 $PF_PID 2>/dev/null; then
            echo "Port-forward died, restarting..."
            start_port_forward
          fi
          echo "Waiting for API... ($i/60)"
          sleep 5
        done

        if [ "$API_READY" != "true" ]; then
          echo "ERROR: Homarr API not available after 5 minutes"
          exit 1
        fi

        # Check if API key already exists in K8s secret and still works
        API_KEY=$(get_secret_value "${ns}" "homarr-credentials" "API_KEY")
        if [ -n "$API_KEY" ]; then
          TEST=$($CURL -s http://localhost:17575/api/trpc/user.getAll -H "ApiKey: $API_KEY" 2>/dev/null)
          if echo "$TEST" | grep -q "UNAUTHORIZED"; then
            echo "API key expired or invalid, regenerating..."
            API_KEY=""
          fi
        fi

        if [ -z "$API_KEY" ]; then
          echo "Configuring admin user and API key..."

          # Step 1: Complete onboarding (start -> user -> settings -> finish)
          CURRENT_STEP=$($CURL -s http://localhost:17575/api/trpc/onboard.currentStep | $JQ -r '.result.data.json.current // empty')
          echo "Onboarding step: $CURRENT_STEP"

          if [ "$CURRENT_STEP" = "start" ]; then
            $CURL -s -X POST http://localhost:17575/api/trpc/onboard.nextStep \
              -H "Content-Type: application/json" \
              -d '{"json":{"step":"start"}}' > /dev/null
            CURRENT_STEP="user"
          fi

          if [ "$CURRENT_STEP" = "user" ]; then
            # Create admin user (initUser only works on "user" step)
            INIT_RESPONSE=$($CURL -s -X POST http://localhost:17575/api/trpc/user.initUser \
              -H "Content-Type: application/json" \
              -d "{\"json\":{\"username\":\"admin\",\"name\":\"Admin\",\"password\":\"$ADMIN_PASSWORD\",\"confirmPassword\":\"$ADMIN_PASSWORD\"}}" 2>/dev/null)
            if echo "$INIT_RESPONSE" | $JQ -e '.result' &>/dev/null; then
              echo "Admin user created"
            else
              echo "WARN: initUser: $(echo "$INIT_RESPONSE" | $JQ -r '.error.json.message // empty' 2>/dev/null)"
            fi

            $CURL -s -X POST http://localhost:17575/api/trpc/onboard.nextStep \
              -H "Content-Type: application/json" \
              -d '{"json":{"step":"user"}}' > /dev/null
            CURRENT_STEP="settings"
          fi

          if [ "$CURRENT_STEP" = "settings" ]; then
            $CURL -s -X POST http://localhost:17575/api/trpc/onboard.nextStep \
              -H "Content-Type: application/json" \
              -d '{"json":{"step":"settings"}}' > /dev/null
            CURRENT_STEP="finish"
          fi

          echo "Onboarding completed (step: $CURRENT_STEP)"

          # Step 2: Create API key directly in SQLite via node
          # NextAuth login has a bug in v1.53.0 (name field not mapped correctly),
          # so we bypass it and insert the key directly in the database.
          API_KEY=$($KUBECTL exec -i -n ${ns} deploy/homarr -- node - < ${homarrCreateApiKeyScript} 2>/dev/null)

          if [ -z "$API_KEY" ]; then
            echo "ERROR: Could not create API key"
            exit 1
          fi

          # Save credentials to K8s secret
          store_credentials "${ns}" "homarr-credentials" \
            "ADMIN_USER=admin" "ADMIN_PASSWORD=$ADMIN_PASSWORD" \
            "API_KEY=$API_KEY" "ENCRYPTION_KEY=$ENCRYPTION_KEY"
          echo "Credentials saved to K8s secret homarr-credentials"
        fi

        echo "API Key obtained"

        # ============================================
        # B) CREATE APPS
        # ============================================
        echo ""
        echo "Creating apps in Homarr..."

        # Fetch existing app names to avoid duplicates
        EXISTING_APPS=$($CURL -s http://localhost:17575/api/trpc/app.getAll \
          -H "ApiKey: $API_KEY" 2>/dev/null | $JQ -r '.result.data.json[].name' 2>/dev/null || echo "")

        create_app() {
          local name="$1" href="$2" icon="$3" desc="$4"
          if echo "$EXISTING_APPS" | grep -qxF "$name"; then
            echo "  App: $name (exists)"
            return
          fi
          $CURL -s -X POST http://localhost:17575/api/trpc/app.create \
            -H "Content-Type: application/json" \
            -H "ApiKey: $API_KEY" \
            -d "{\"json\":{\"name\":\"$name\",\"href\":\"$href\",\"iconUrl\":\"$icon\",\"description\":\"$desc\",\"pingUrl\":\"\"}}" > /dev/null 2>&1 || true
          echo "  App: $name (created)"
        }

        create_app "Vaultwarden" "https://$(hostname vault)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/bitwarden.svg" "Password Manager"
        create_app "Authentik" "https://$(hostname auth)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/authentik.svg" "SSO/Identity"
        create_app "Nextcloud" "https://$(hostname cloud)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/nextcloud.svg" "Cloud Storage"
        create_app "Syncthing" "https://$(hostname sync)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/syncthing.svg" "File Sync"
        create_app "Grafana" "https://$(hostname grafana)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/grafana.svg" "Dashboards"
        create_app "Prometheus" "https://$(hostname prometheus)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/prometheus.svg" "Metrics"
        create_app "Alertmanager" "https://$(hostname alertmanager)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/alertmanager.svg" "Alerts"
        create_app "Uptime Kuma" "https://$(hostname status)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/uptime-kuma.svg" "Status Monitoring"
        create_app "Jellyfin" "https://$(hostname jellyfin)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/jellyfin.svg" "Media Server"
        create_app "Jellyseerr" "https://$(hostname requests)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/jellyseerr.svg" "Media Requests"
        create_app "Sonarr" "https://$(hostname sonarr)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/sonarr.svg" "TV Shows"
        create_app "Sonarr ES" "https://$(hostname sonarr-es)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/sonarr.svg" "Series (ES)"
        create_app "Radarr" "https://$(hostname radarr)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/radarr.svg" "Movies"
        create_app "Radarr ES" "https://$(hostname radarr-es)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/radarr.svg" "Movies (ES)"
        create_app "Lidarr" "https://$(hostname lidarr)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/lidarr.svg" "Music"
        create_app "Prowlarr" "https://$(hostname prowlarr)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/prowlarr.svg" "Indexers"
        create_app "Bazarr" "https://$(hostname bazarr)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/bazarr.svg" "Subtitles"
        create_app "qBittorrent" "https://$(hostname qbit)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/qbittorrent.svg" "Downloads"
        create_app "Immich" "https://$(hostname photos)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/immich.svg" "Photo Backup"
        create_app "Bookshelf" "https://$(hostname books)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/readarr.svg" "Ebooks"
        create_app "Kavita" "https://$(hostname kavita)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/kavita.svg" "Manga/Comics"
        create_app "Kiwix" "https://$(hostname wiki)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/kiwix.svg" "Offline Knowledge"
        create_app "Traefik" "https://$(hostname traefik)" "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/traefik.svg" "Ingress Controller"
        echo "Apps created"

        # ============================================
        # C) CREATE INTEGRATIONS
        # ============================================
        echo ""
        echo "Creating integrations in Homarr..."

        # Read API keys from K8s Secrets
        SONARR_KEY=$(get_secret_value media sonarr-api-key api-key)
        SONARR_ES_KEY=$(get_secret_value media sonarr-es-api-key api-key)
        RADARR_KEY=$(get_secret_value media radarr-api-key api-key)
        RADARR_ES_KEY=$(get_secret_value media radarr-es-api-key api-key)
        LIDARR_KEY=$(get_secret_value media lidarr-api-key api-key)
        PROWLARR_KEY=$(get_secret_value media prowlarr-api-key api-key)

        QBIT_PASSWORD=$(get_secret_value media qbittorrent-credentials PASSWORD)

        # Jellyfin API key
        JF_API_KEY=""
        JF_ADMIN_USER=$(get_secret_value media jellyfin-credentials ADMIN_USER)
        JF_ADMIN_PASSWORD=$(get_secret_value media jellyfin-credentials ADMIN_PASSWORD)
        if [ -n "$JF_ADMIN_USER" ] && [ -n "$JF_ADMIN_PASSWORD" ]; then
          JF_AUTH=$($KUBECTL exec -n media deploy/jellyfin -- \
            curl -s -X POST "http://localhost:8096/Users/AuthenticateByName" \
            -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: MediaBrowser Client=\"Homarr\", Device=\"NixOS\", DeviceId=\"homarr\", Version=\"1.0\"" \
            -d "{\"Username\":\"$JF_ADMIN_USER\",\"Pw\":\"$JF_ADMIN_PASSWORD\"}" 2>/dev/null || echo "{}")
          JF_TOKEN=$(echo "$JF_AUTH" | $JQ -r '.AccessToken // empty' 2>/dev/null)
          if [ -n "$JF_TOKEN" ]; then
            JF_API_KEY=$($KUBECTL exec -n media deploy/jellyfin -- \
              curl -s "http://localhost:8096/Auth/Keys?api_key=$JF_TOKEN" 2>/dev/null | \
              $JQ -r '.Items[] | select(.AppName == "ArrStack") | .AccessToken' 2>/dev/null || echo "")
          fi
        fi

        # Jellyseerr API key
        JSEERR_KEY=$($KUBECTL exec -n media deploy/jellyseerr -- \
          cat /app/config/settings.json 2>/dev/null | $JQ -r '.main.apiKey // empty' 2>/dev/null || echo "")

        # Fetch existing integration names to avoid duplicates
        EXISTING_INTEGRATIONS=$($CURL -s http://localhost:17575/api/trpc/integration.getAll \
          -H "ApiKey: $API_KEY" 2>/dev/null | $JQ -r '.result.data.json[].name' 2>/dev/null || echo "")

        create_integration() {
          local kind="$1" name="$2" url="$3"
          shift 3
          local secrets_json="$1"

          if echo "$EXISTING_INTEGRATIONS" | grep -qxF "$name"; then
            echo "  Integration: $name (exists)"
            return
          fi

          RESPONSE=$($CURL -s -X POST http://localhost:17575/api/trpc/integration.create \
            -H "Content-Type: application/json" \
            -H "ApiKey: $API_KEY" \
            -d "{\"json\":{\"name\":\"$name\",\"kind\":\"$kind\",\"url\":\"$url\",\"secrets\":$secrets_json,\"attemptSearchEngineCreation\":false}}" 2>/dev/null || echo "{}")

          ERROR=$(echo "$RESPONSE" | $JQ -r '.error.message // empty' 2>/dev/null)
          if [ -n "$ERROR" ]; then
            echo "  WARN: Integration $name: $ERROR"
          else
            echo "  Integration: $name (created)"
          fi
        }

        # Sonarr
        if [ -n "$SONARR_KEY" ]; then
          create_integration "sonarr" "Sonarr" "http://sonarr.media.svc:8989" \
            "[{\"kind\":\"apiKey\",\"value\":\"$SONARR_KEY\"}]"
        fi

        # Sonarr ES
        if [ -n "$SONARR_ES_KEY" ]; then
          create_integration "sonarr" "Sonarr ES" "http://sonarr-es.media.svc:8989" \
            "[{\"kind\":\"apiKey\",\"value\":\"$SONARR_ES_KEY\"}]"
        fi

        # Radarr
        if [ -n "$RADARR_KEY" ]; then
          create_integration "radarr" "Radarr" "http://radarr.media.svc:7878" \
            "[{\"kind\":\"apiKey\",\"value\":\"$RADARR_KEY\"}]"
        fi

        # Radarr ES
        if [ -n "$RADARR_ES_KEY" ]; then
          create_integration "radarr" "Radarr ES" "http://radarr-es.media.svc:7878" \
            "[{\"kind\":\"apiKey\",\"value\":\"$RADARR_ES_KEY\"}]"
        fi

        # Lidarr
        if [ -n "$LIDARR_KEY" ]; then
          create_integration "lidarr" "Lidarr" "http://lidarr.media.svc:8686" \
            "[{\"kind\":\"apiKey\",\"value\":\"$LIDARR_KEY\"}]"
        fi

        # Prowlarr
        if [ -n "$PROWLARR_KEY" ]; then
          create_integration "prowlarr" "Prowlarr" "http://prowlarr.media.svc:9696" \
            "[{\"kind\":\"apiKey\",\"value\":\"$PROWLARR_KEY\"}]"
        fi

        # qBittorrent
        if [ -n "$QBIT_PASSWORD" ]; then
          create_integration "qBittorrent" "qBittorrent" "http://qbittorrent.media.svc:8080" \
            "[{\"kind\":\"username\",\"value\":\"admin\"},{\"kind\":\"password\",\"value\":\"$QBIT_PASSWORD\"}]"
        fi

        # Jellyfin
        if [ -n "$JF_API_KEY" ]; then
          create_integration "jellyfin" "Jellyfin" "http://jellyfin.media.svc:8096" \
            "[{\"kind\":\"apiKey\",\"value\":\"$JF_API_KEY\"}]"
        fi

        # Jellyseerr
        if [ -n "$JSEERR_KEY" ]; then
          create_integration "jellyseerr" "Jellyseerr" "http://jellyseerr.media.svc:5055" \
            "[{\"kind\":\"apiKey\",\"value\":\"$JSEERR_KEY\"}]"
        fi

        echo "Integrations created"

        # ============================================
        # D) CREATE BOARD WITH WIDGETS
        # ============================================
        echo ""
        echo "Creating board..."

        # Create default board (auto-sets as home board for the creator)
        BOARD_RESPONSE=$($CURL -s -X POST http://localhost:17575/api/trpc/board.createBoard \
          -H "Content-Type: application/json" \
          -H "ApiKey: $API_KEY" \
          -d '{"json":{"name":"Homelab","columnCount":12,"isPublic":false}}' 2>/dev/null || echo "{}")

        BOARD_ID=$(echo "$BOARD_RESPONSE" | $JQ -r '.result.data.json.boardId // empty' 2>/dev/null)

        if [ -n "$BOARD_ID" ] && [ "$BOARD_ID" != "null" ]; then
          echo "Board created: $BOARD_ID"
        else
          echo "WARN: Could not create board (may already exist)"
          echo "Response: $(echo "$BOARD_RESPONSE" | $JQ -r '.error.json.message // empty' 2>/dev/null)"
        fi

        # Populate board with apps in categorized sections via SQLite
        # The tRPC API field names are non-obvious, so SQLite is more reliable
        $KUBECTL exec -i -n ${ns} deploy/homarr -- node - < ${homarrPopulateBoardScript} 2>/dev/null || echo "WARN: Could not populate board via SQLite"

        # ============================================
        # D2) ADMIN-ONLY INFRASTRUCTURE BOARD
        # ============================================
        echo ""
        echo "Creating Infrastructure board (admin-only)..."

        INFRA_BOARD_RESPONSE=$($CURL -s -X POST http://localhost:17575/api/trpc/board.createBoard \
          -H "Content-Type: application/json" \
          -H "ApiKey: $API_KEY" \
          -d '{"json":{"name":"Infrastructure","columnCount":12,"isPublic":false}}' 2>/dev/null || echo "{}")

        INFRA_BOARD_ID=$(echo "$INFRA_BOARD_RESPONSE" | $JQ -r '.result.data.json.boardId // empty' 2>/dev/null)
        if [ -n "$INFRA_BOARD_ID" ] && [ "$INFRA_BOARD_ID" != "null" ]; then
          echo "Infrastructure board created: $INFRA_BOARD_ID"
        else
          echo "WARN: Could not create Infrastructure board (may already exist)"
        fi

        # Populate Infrastructure board and set admin group permissions
        $KUBECTL exec -i -n ${ns} deploy/homarr -- node - < ${homarrPopulateInfraBoardScript} 2>/dev/null || echo "WARN: Could not populate Infrastructure board"

        # ============================================
        # E) OIDC CONFIGURATION
        # ============================================
        echo ""
        echo "Configuring OIDC..."

        # Check if SSO credentials exist for Homarr
        HOMARR_CLIENT_SECRET=""
        if $KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.HOMARR_CLIENT_SECRET}' &>/dev/null; then
          HOMARR_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.HOMARR_CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null)
        fi

        if [ -n "$HOMARR_CLIENT_SECRET" ]; then
          echo "Applying OIDC env vars..."

          # Set OIDC env vars directly on the deployment (overrides Helm chart defaults)
          # kubectl set env modifies the env: entries in-place, avoiding the envFrom precedence issue
          $KUBECTL set env deployment/homarr -n ${ns} \
            AUTH_PROVIDERS=credentials,oidc \
            AUTH_OIDC_CLIENT_NAME=authentik \
            AUTH_OIDC_CLIENT_ID=homarr \
            AUTH_OIDC_CLIENT_SECRET="$HOMARR_CLIENT_SECRET" \
            "AUTH_OIDC_ISSUER=https://$(hostname auth)/application/o/homarr/" \
            "AUTH_OIDC_URI=https://$(hostname auth)/application/o/authorize/" \
            AUTH_OIDC_AUTO_LOGIN=false \
            "AUTH_OIDC_SCOPE_OVERWRITE=openid email profile groups" \
            AUTH_OIDC_GROUPS_ATTRIBUTE=groups

          # Remove stale envFrom if present from previous approach
          if $KUBECTL get deployment homarr -n ${ns} -o jsonpath='{.spec.template.spec.containers[*].envFrom}' 2>/dev/null | grep -q "homarr-oidc-env"; then
            $KUBECTL patch deployment homarr -n ${ns} --type=json \
              -p='[{"op":"remove","path":"/spec/template/spec/containers/0/envFrom"}]' 2>/dev/null || true
          fi

          wait_for_deployment "${ns}" "homarr" 180
          echo "OIDC configured"
        else
          echo "WARN: No OIDC credentials found for Homarr, skipping OIDC"
          echo "Run authentik-sso-setup again to generate credentials"
        fi

        print_success "Homarr Config" \
          "URL: https://$(hostname home)" \
          "Credentials stored in K8s secret homarr-credentials" \
          "OIDC: Sign in with Authentik (if configured)"

        create_marker "${configMarkerFile}"
      '';
    };
  };
}
