{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "authentik";
  markerFile = "/var/lib/authentik-sso-setup-done";
  domain = "${serverConfig.subdomain}.${serverConfig.domain}";
in
{
  systemd.services.authentik-sso-setup = {
    description = "Setup Authentik SSO integration for all services";
    # After Tier 3 Core (authentik already installed)
    after = [
      "k3s-core.target"
      "authentik-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [ "authentik-setup.service" ];
    wantedBy = [ "k3s-media.target" ]; # Ready before media starts

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "authentik-sso-setup" ''
                ${k8s.libShSource}

                setup_preamble "${markerFile}" "Authentik SSO"
                wait_for_k3s

                # Configure CoreDNS for local DNS resolution using custom ConfigMap
                echo "Configuring CoreDNS to resolve local domains..."

                # Get Traefik LoadBalancer IP (with retries)
                TRAEFIK_IP=""
                for i in $(seq 1 30); do
                  TRAEFIK_IP=$($KUBECTL get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
                  if [ -n "$TRAEFIK_IP" ]; then
                    echo "Traefik IP: $TRAEFIK_IP"
                    break
                  fi
                  echo "Waiting for Traefik LoadBalancer IP... ($i/30)"
                  sleep 5
                done

                if [ -z "$TRAEFIK_IP" ]; then
                  echo "WARN: Could not get Traefik IP, using configured IP"
                  TRAEFIK_IP="${serverConfig.traefikIP}"
                fi

                # Check if CoreDNS custom config already exists and is correct
                CURRENT_CONFIG=$($KUBECTL get configmap coredns-custom -n kube-system -o jsonpath='{.data.local-dns\.server}' 2>/dev/null || echo "")
                if echo "$CURRENT_CONFIG" | grep -q "${serverConfig.traefikIP}"; then
                  echo "CoreDNS already configured correctly"
                else
                  echo "Creating/updating CoreDNS configuration..."

                  # Create custom CoreDNS configuration using template plugin
                  cat <<EOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: coredns-custom
          namespace: kube-system
        data:
          local-dns.server: |
            ${domain}:53 {
              errors
              cache 30
              template IN A ${domain} {
                match "^(.+\\.)?${domain}\\.$"
                answer "{{ .Name }} 60 IN A ${serverConfig.traefikIP}"
                fallthrough
              }
              template IN AAAA ${domain} {
                match "^(.+\\.)?${domain}\\.$"
                rcode NOERROR
                fallthrough
              }
            }
        EOF

                  # Restart CoreDNS to pick up custom config (with grace period)
                  echo "Restarting CoreDNS..."
                  $KUBECTL rollout restart deployment/coredns -n kube-system 2>/dev/null || true
                  sleep 10

                  # Wait for CoreDNS to be ready (non-blocking)
                  $KUBECTL rollout status deployment/coredns -n kube-system --timeout=120s || {
                    echo "WARN: CoreDNS restart took longer than expected, continuing..."
                  }

                  echo "CoreDNS configured: *.${domain} -> ${serverConfig.traefikIP}"
                fi

                # Wait for Authentik to be ready
                echo "Waiting for Authentik..."
                for i in $(seq 1 90); do
                  if $KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=authentik -l app.kubernetes.io/component=server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
                    echo "Authentik pod Running"
                    break
                  fi
                  echo "Waiting for Authentik... ($i/90)"
                  sleep 10
                done

                AUTHENTIK_POD=$($KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=authentik -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')
                if [ -z "$AUTHENTIK_POD" ]; then
                  echo "ERROR: Authentik pod not found"
                  exit 1
                fi

                # Read credentials from K8s secrets
                BOOTSTRAP_TOKEN=$(get_secret_value "${ns}" "authentik-setup-credentials" "BOOTSTRAP_TOKEN")
                ADMIN_PASS=$(get_secret_value "${ns}" "authentik-setup-credentials" "PASSWORD")

                # Read saved API token from K8s secret
                SAVED_API_TOKEN=$(get_secret_value "${ns}" "authentik-api-token" "TOKEN")

                if [ -z "$BOOTSTRAP_TOKEN" ] && [ -z "$ADMIN_PASS" ] && [ -z "$SAVED_API_TOKEN" ]; then
                  echo "ERROR: No credentials found"
                  exit 1
                fi

                # Kill any existing port-forward (broad pattern to catch zombies)
                pkill -f 'port-forward.*19000' 2>/dev/null || true
                pkill -f 'port-forward.*authentik-server' 2>/dev/null || true
                sleep 5

                $KUBECTL port-forward -n ${ns} svc/authentik-server 19000:80 &
                PF_PID=$!
                trap "kill $PF_PID 2>/dev/null || true" EXIT
                sleep 5

                API="http://localhost:19000/api/v3"

                # Wait for Authentik to respond (needs time for DB migrations after restart)
                echo "Waiting for Authentik API..."
                for i in $(seq 1 60); do
                  if $CURL -sf "http://localhost:19000/-/health/live/" &>/dev/null; then
                    echo "Authentik is alive"
                    break
                  fi
                  if ! kill -0 $PF_PID 2>/dev/null; then
                    $KUBECTL port-forward -n ${ns} svc/authentik-server 19000:80 &
                    PF_PID=$!
                    trap "kill $PF_PID 2>/dev/null || true" EXIT
                    sleep 3
                  fi
                  echo "Waiting for Authentik... ($i/60)"
                  sleep 5
                done

                if ! $CURL -sf "http://localhost:19000/-/health/live/" &>/dev/null; then
                  echo "ERROR: Authentik not available"
                  exit 1
                fi

                # Auth chain: saved token -> bootstrap token -> fail
                AUTH=""

                # 1. Try saved API token from previous run
                if [ -n "$SAVED_API_TOKEN" ]; then
                  if $CURL -sf "$API/core/applications/" -H "Authorization: Bearer $SAVED_API_TOKEN" &>/dev/null; then
                    AUTH="Authorization: Bearer $SAVED_API_TOKEN"
                    echo "Using saved API token"
                  else
                    echo "Saved API token expired"
                  fi
                fi

                # 2. Try bootstrap token
                if [ -z "$AUTH" ] && [ -n "$BOOTSTRAP_TOKEN" ]; then
                  if $CURL -sf "$API/core/applications/" -H "Authorization: Bearer $BOOTSTRAP_TOKEN" &>/dev/null; then
                    AUTH="Authorization: Bearer $BOOTSTRAP_TOKEN"
                    echo "Using bootstrap token"

                    # Create persistent API token for future re-runs
                    $CURL -s -X POST "$API/core/tokens/" \
                      -H "$AUTH" -H "Content-Type: application/json" \
                      -d '{"identifier":"sso-setup-api","intent":"api","description":"SSO setup automation"}' > /dev/null 2>&1 || true
                    sleep 2
                    PERSISTENT_KEY=$($CURL -s "$API/core/tokens/sso-setup-api/view_key/" \
                      -H "$AUTH" 2>/dev/null | $JQ -r '.key // empty' 2>/dev/null || echo "")
                    if [ -n "$PERSISTENT_KEY" ]; then
                      store_credentials "${ns}" "authentik-api-token" "TOKEN=$PERSISTENT_KEY"
                      echo "Persistent API token saved to K8s secret"
                    fi
                  else
                    echo "Bootstrap token expired"
                  fi
                fi

                if [ -z "$AUTH" ]; then
                  echo "ERROR: No valid Authentik API token available"
                  echo "  Bootstrap token and saved token both failed."
                  echo "  To fix: delete marker /var/lib/authentik-setup-done and re-run authentik-setup"
                  exit 1
                fi
                echo "API available"

                # Invalidate bootstrap token (no longer needed after API token is created)
                if [ -n "$SAVED_API_TOKEN" ] && [ "$AUTH" = "Authorization: Bearer $SAVED_API_TOKEN" ]; then
                  $KUBECTL exec -n ${ns} deploy/authentik-server -- \
                    ak shell -c "from authentik.core.models import Token; Token.objects.filter(identifier='bootstrap-token').delete()" \
                    2>/dev/null || true
                  echo "Bootstrap token invalidated"
                fi

                # Reuse existing client secrets if available, generate only if missing
                EXISTING_SECRET=$($KUBECTL get secret authentik-sso-credentials -n traefik-system -o json 2>/dev/null || echo "{}")
                get_existing() {
                  echo "$EXISTING_SECRET" | $JQ -r ".data.\"$1\" // empty" 2>/dev/null | base64 -d 2>/dev/null || echo ""
                }

                GRAFANA_CLIENT_SECRET=$(get_existing GRAFANA_CLIENT_SECRET)
                NEXTCLOUD_CLIENT_SECRET=$(get_existing NEXTCLOUD_CLIENT_SECRET)
                JELLYFIN_CLIENT_SECRET=$(get_existing JELLYFIN_CLIENT_SECRET)
                JELLYSEERR_CLIENT_SECRET=$(get_existing JELLYSEERR_CLIENT_SECRET)
                IMMICH_CLIENT_SECRET=$(get_existing IMMICH_CLIENT_SECRET)
                VAULTWARDEN_CLIENT_SECRET=$(get_existing VAULTWARDEN_CLIENT_SECRET)
                UPTIME_KUMA_CLIENT_SECRET=$(get_existing UPTIME_KUMA_CLIENT_SECRET)
                HOMARR_CLIENT_SECRET=$(get_existing HOMARR_CLIENT_SECRET)
                KAVITA_CLIENT_SECRET=$(get_existing KAVITA_CLIENT_SECRET)

                # Generate new secrets only for missing ones
                [ -z "$GRAFANA_CLIENT_SECRET" ] && GRAFANA_CLIENT_SECRET=$(generate_hex 32)
                [ -z "$NEXTCLOUD_CLIENT_SECRET" ] && NEXTCLOUD_CLIENT_SECRET=$(generate_hex 32)
                [ -z "$JELLYFIN_CLIENT_SECRET" ] && JELLYFIN_CLIENT_SECRET=$(generate_hex 32)
                [ -z "$JELLYSEERR_CLIENT_SECRET" ] && JELLYSEERR_CLIENT_SECRET=$(generate_hex 32)
                [ -z "$IMMICH_CLIENT_SECRET" ] && IMMICH_CLIENT_SECRET=$(generate_hex 32)
                [ -z "$VAULTWARDEN_CLIENT_SECRET" ] && VAULTWARDEN_CLIENT_SECRET=$(generate_hex 32)
                [ -z "$UPTIME_KUMA_CLIENT_SECRET" ] && UPTIME_KUMA_CLIENT_SECRET=$(generate_hex 32)
                [ -z "$HOMARR_CLIENT_SECRET" ] && HOMARR_CLIENT_SECRET=$(generate_hex 32)
                [ -z "$KAVITA_CLIENT_SECRET" ] && KAVITA_CLIENT_SECRET=$(generate_hex 32)

                # ============================================
                # GET REQUIRED RESOURCES
                # ============================================

                # Get authorization flow PK
                AUTH_FLOW_PK=$($CURL -s "$API/flows/instances/?slug=default-provider-authorization-implicit-consent" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                if [ -z "$AUTH_FLOW_PK" ]; then
                  AUTH_FLOW_PK=$($CURL -s "$API/flows/instances/" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                fi
                echo "Authorization flow: $AUTH_FLOW_PK"

                # Get invalidation flow PK (required since Authentik 2024.8+)
                INVALIDATION_FLOW_PK=$($CURL -s "$API/flows/instances/?slug=default-provider-invalidation-flow" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                if [ -z "$INVALIDATION_FLOW_PK" ]; then
                  INVALIDATION_FLOW_PK="$AUTH_FLOW_PK"
                  echo "Invalidation flow: using authorization flow as fallback"
                else
                  echo "Invalidation flow: $INVALIDATION_FLOW_PK"
                fi

                # Get signing key PK
                SIGNING_KEY_PK=$($CURL -s "$API/crypto/certificatekeypairs/" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                echo "Signing key: $SIGNING_KEY_PK"

                # Get scope mappings (openid, email, profile)
                SCOPE_MAPPINGS=$($CURL -s "$API/propertymappings/provider/scope/" -H "$AUTH" | $JQ '[.results[] | select(.scope_name == "openid" or .scope_name == "email" or .scope_name == "profile") | .pk]')
                echo "Scope mappings: $SCOPE_MAPPINGS"

                if [ -z "$AUTH_FLOW_PK" ] || [ -z "$SIGNING_KEY_PK" ]; then
                  kill $PF_PID 2>/dev/null || true
                  echo "ERROR: Flow or signing key not found"
                  exit 1
                fi

                # ============================================
                # CREATE GROUPS
                # ============================================
                for group_name in admins media-admins media-users family monitoring; do
                  EXISTING=$($CURL -s "$API/core/groups/?name=$group_name" -H "$AUTH" | $JQ -r '.pagination.count')
                  if [ "$EXISTING" = "0" ]; then
                    $CURL -s -X POST "$API/core/groups/" -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{\"name\":\"$group_name\"}" > /dev/null
                    echo "Group $group_name: created"
                  else
                    echo "Group $group_name: exists"
                  fi
                done

                # ============================================
                # CREATE OIDC PROVIDERS AND APPLICATIONS
                # ============================================

                create_oidc_app() {
                  local APP_NAME="$1"
                  local SLUG="$2"
                  local CLIENT_ID="$3"
                  local CLIENT_SECRET="$4"
                  local LAUNCH_URL="$5"
                  local REDIRECT_URI="$6"

                  # Check if provider already exists
                  PROVIDER_PK=$($CURL -s "$API/providers/oauth2/?search=$APP_NAME+Provider" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

                  if [ -z "$PROVIDER_PK" ]; then
                    # Create provider
                    PROVIDER_RESPONSE=$($CURL -s -X POST "$API/providers/oauth2/" -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{
                        \"name\": \"$APP_NAME Provider\",
                        \"authorization_flow\": \"$AUTH_FLOW_PK\",
                        \"invalidation_flow\": \"$INVALIDATION_FLOW_PK\",
                        \"client_type\": \"confidential\",
                        \"client_id\": \"$CLIENT_ID\",
                        \"client_secret\": \"$CLIENT_SECRET\",
                        \"signing_key\": \"$SIGNING_KEY_PK\",
                        \"property_mappings\": $SCOPE_MAPPINGS,
                        \"redirect_uris\": [{\"url\": \"$REDIRECT_URI\", \"matching_mode\": \"strict\"}],
                        \"include_claims_in_id_token\": true,
                        \"access_code_validity\": \"minutes=1\",
                        \"access_token_validity\": \"hours=1\",
                        \"refresh_token_validity\": \"days=30\"
                      }")
                    PROVIDER_PK=$(echo "$PROVIDER_RESPONSE" | $JQ -r '.pk // empty')
                    if [ -n "$PROVIDER_PK" ]; then
                      echo "$APP_NAME Provider: created (pk=$PROVIDER_PK)"
                    else
                      # Provider creation failed, try to find by client_id
                      echo "WARN: $APP_NAME Provider creation failed, searching by client_id..."
                      PROVIDER_PK=$($CURL -s "$API/providers/oauth2/?client_id=$CLIENT_ID" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                      if [ -n "$PROVIDER_PK" ]; then
                        echo "$APP_NAME Provider: found existing (pk=$PROVIDER_PK)"
                      else
                        echo "ERROR: $APP_NAME Provider: $(echo "$PROVIDER_RESPONSE" | $JQ -r '.' 2>/dev/null || echo "$PROVIDER_RESPONSE")"
                        return 0  # Continue instead of failing
                      fi
                    fi
                  else
                    # Update existing provider with new secret
                    $CURL -s -X PATCH "$API/providers/oauth2/$PROVIDER_PK/" -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{
                        \"client_secret\": \"$CLIENT_SECRET\",
                        \"redirect_uris\": [{\"url\": \"$REDIRECT_URI\", \"matching_mode\": \"strict\"}]
                      }" > /dev/null
                    echo "$APP_NAME Provider: updated (pk=$PROVIDER_PK)"
                  fi

                  # Check if application already exists
                  APP_EXISTS=$($CURL -s "$API/core/applications/?slug=$SLUG" -H "$AUTH" | $JQ -r '.pagination.count')
                  if [ "$APP_EXISTS" = "0" ]; then
                    $CURL -s -X POST "$API/core/applications/" -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{
                        \"name\": \"$APP_NAME\",
                        \"slug\": \"$SLUG\",
                        \"provider\": $PROVIDER_PK,
                        \"meta_launch_url\": \"$LAUNCH_URL\"
                      }" > /dev/null
                    echo "$APP_NAME App: created"
                  else
                    $CURL -s -X PATCH "$API/core/applications/?slug=$SLUG" -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{\"provider\": $PROVIDER_PK}" > /dev/null 2>&1 || true
                    echo "$APP_NAME App: exists"
                  fi
                }

                echo ""
                echo "Creating OIDC providers and applications..."
                echo ""

                create_oidc_app "Grafana" "grafana" "grafana" "$GRAFANA_CLIENT_SECRET" \
                  "https://grafana.${domain}" \
                  "https://grafana.${domain}/login/generic_oauth"

                create_oidc_app "Nextcloud" "nextcloud" "nextcloud" "$NEXTCLOUD_CLIENT_SECRET" \
                  "https://cloud.${domain}" \
                  "https://cloud.${domain}/apps/user_oidc/code"

                create_oidc_app "Jellyfin" "jellyfin" "jellyfin" "$JELLYFIN_CLIENT_SECRET" \
                  "https://jellyfin.${domain}" \
                  "https://jellyfin.${domain}/sso/OID/redirect/Authentik"

                create_oidc_app "Jellyseerr" "jellyseerr" "jellyseerr" "$JELLYSEERR_CLIENT_SECRET" \
                  "https://requests.${domain}" \
                  "https://requests.${domain}/login?provider=authentik&callback=true"

                create_oidc_app "Immich" "immich" "immich" "$IMMICH_CLIENT_SECRET" \
                  "https://photos.${domain}" \
                  "https://photos.${domain}/auth/login"

                create_oidc_app "Vaultwarden" "vaultwarden" "vaultwarden" "$VAULTWARDEN_CLIENT_SECRET" \
                  "https://vault.${domain}" \
                  "https://vault.${domain}/identity/connect/oidc-signin"

                create_oidc_app "Uptime Kuma" "uptime-kuma" "uptime-kuma" "$UPTIME_KUMA_CLIENT_SECRET" \
                  "https://status.${domain}" \
                  "https://status.${domain}/api/auth/oidc/callback"

                create_oidc_app "Homarr" "homarr" "homarr" "$HOMARR_CLIENT_SECRET" \
                  "https://home.${domain}" \
                  "https://home.${domain}/api/auth/callback/oidc"

                create_oidc_app "Kavita" "kavita" "kavita" "$KAVITA_CLIENT_SECRET" \
                  "https://kavita.${domain}" \
                  "https://kavita.${domain}/signin-oidc"

                # ============================================
                # KAVITA ROLES SCOPE MAPPING
                # ============================================
                KAVITA_ROLES_EXISTING=$($CURL -s "$API/propertymappings/provider/scope/?scope_name=kavita_roles" -H "$AUTH" | $JQ -r '.pagination.count')
                if [ "$KAVITA_ROLES_EXISTING" = "0" ]; then
                  KAVITA_ROLES_TMP=$(mktemp)
                  cat > "$KAVITA_ROLES_TMP" << 'MAPPING'
        {
          "name": "Kavita Roles",
          "scope_name": "kavita_roles",
          "expression": "roles = []\nfor group in request.user.ak_groups.all():\n    if group.name == \"admins\":\n        roles.extend([\"Admin\", \"Login\", \"Pleb\"])\n    elif group.name in [\"media-users\", \"media-admins\", \"family\"]:\n        roles.extend([\"Login\", \"Pleb\"])\nif not roles:\n    roles.extend([\"Login\", \"Pleb\"])\nreturn {\"kavita_roles\": list(set(roles))}"
        }
        MAPPING
                  KAVITA_ROLES_PK=$($CURL -s -X POST "$API/propertymappings/provider/scope/" \
                    -H "$AUTH" -H "Content-Type: application/json" \
                    -d @"$KAVITA_ROLES_TMP" | $JQ -r '.pk // empty')
                  rm -f "$KAVITA_ROLES_TMP"
                  echo "Kavita roles mapping: created ($KAVITA_ROLES_PK)"
                else
                  KAVITA_ROLES_PK=$($CURL -s "$API/propertymappings/provider/scope/?scope_name=kavita_roles" -H "$AUTH" | $JQ -r '.results[0].pk')
                  echo "Kavita roles mapping: exists ($KAVITA_ROLES_PK)"
                fi

                # Add mapping to Kavita provider
                if [ -n "$KAVITA_ROLES_PK" ]; then
                  KAVITA_PROVIDER_PK=$($CURL -s "$API/providers/oauth2/?search=Kavita+Provider" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                  if [ -n "$KAVITA_PROVIDER_PK" ]; then
                    CURRENT_MAPPINGS=$($CURL -s "$API/providers/oauth2/$KAVITA_PROVIDER_PK/" -H "$AUTH" | $JQ '.property_mappings')
                    UPDATED_MAPPINGS=$(echo "$CURRENT_MAPPINGS" | $JQ --arg pk "$KAVITA_ROLES_PK" '. + [$pk] | unique')
                    $CURL -s -X PATCH "$API/providers/oauth2/$KAVITA_PROVIDER_PK/" \
                      -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{\"property_mappings\": $UPDATED_MAPPINGS}" > /dev/null
                    echo "Kavita roles mapping: added to provider"
                  fi
                fi

                # ============================================
                # CREATE FORWARDAUTH MIDDLEWARE
                # ============================================
                if ! $KUBECTL get middleware -n traefik-system authentik-forward-auth &>/dev/null; then
                  echo "Creating ForwardAuth middleware..."
                  cat <<EOF | $KUBECTL apply -f -
        apiVersion: traefik.io/v1alpha1
        kind: Middleware
        metadata:
          name: authentik-forward-auth
          namespace: traefik-system
        spec:
          forwardAuth:
            address: http://authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik
            trustForwardHeader: true
            authResponseHeaders:
              - X-authentik-username
              - X-authentik-groups
              - X-authentik-email
              - X-authentik-name
              - X-authentik-uid
        EOF
                else
                  echo "ForwardAuth middleware: exists"
                fi

                # ============================================
                # CREATE FORWARDAUTH PROXY PROVIDERS
                # ============================================
                echo ""
                echo "Creating ForwardAuth proxy providers..."

                # Get or create proxy outpost (reused by nas-apps if it runs later)
                OUTPOST_PK=$($CURL -s "$API/outposts/instances/?type=proxy" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                if [ -z "$OUTPOST_PK" ]; then
                  echo "Creating proxy outpost..."
                  SERVICE_CONNECTION_PK=$($CURL -s "$API/outposts/service_connections/all/?name=authentik%20Embedded%20Outpost" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                  if [ -z "$SERVICE_CONNECTION_PK" ]; then
                    SERVICE_CONNECTION_PK=$($CURL -s "$API/outposts/service_connections/all/" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                  fi
                  OUTPOST_RESPONSE=$($CURL -s -X POST "$API/outposts/instances/" -H "$AUTH" -H "Content-Type: application/json" \
                    -d "{
                      \"name\": \"Proxy Outpost\",
                      \"type\": \"proxy\",
                      \"service_connection\": \"$SERVICE_CONNECTION_PK\",
                      \"config\": {
                        \"authentik_host\": \"https://$(hostname auth)/\",
                        \"log_level\": \"info\"
                      }
                    }")
                  OUTPOST_PK=$(echo "$OUTPOST_RESPONSE" | $JQ -r '.pk // empty')
                  if [ -n "$OUTPOST_PK" ]; then
                    echo "Outpost created: $OUTPOST_PK"
                  else
                    echo "WARN: Could not create proxy outpost"
                  fi
                else
                  echo "Existing outpost: $OUTPOST_PK"
                  CURRENT_HOST=$($CURL -s "$API/outposts/instances/$OUTPOST_PK/" -H "$AUTH" | $JQ -r '.config.authentik_host // empty')
                  if [ -z "$CURRENT_HOST" ]; then
                    $CURL -s -X PATCH "$API/outposts/instances/$OUTPOST_PK/" -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{\"config\": {\"authentik_host\": \"https://$(hostname auth)/\"}}" > /dev/null
                  fi
                fi

                create_forward_auth_app() {
                  local APP_NAME="$1"
                  local SLUG="$2"
                  local EXTERNAL_HOST="$3"
                  local SKIP_PATH="''${4:-}"

                  SEARCH_QUERY=$(echo "$APP_NAME Forward Auth" | sed 's/ /+/g')
                  PROVIDER_PK=$($CURL -s "$API/providers/proxy/?search=$SEARCH_QUERY" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

                  if [ -z "$PROVIDER_PK" ]; then
                    SKIP_FIELD=""
                    if [ -n "$SKIP_PATH" ]; then
                      SKIP_FIELD=",\"skip_path_regex\": \"$SKIP_PATH\""
                    fi
                    PROVIDER_RESPONSE=$($CURL -s -X POST "$API/providers/proxy/" -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{
                        \"name\": \"$APP_NAME Forward Auth\",
                        \"authorization_flow\": \"$AUTH_FLOW_PK\",
                        \"invalidation_flow\": \"$INVALIDATION_FLOW_PK\",
                        \"mode\": \"forward_single\",
                        \"external_host\": \"$EXTERNAL_HOST\",
                        \"certificate\": \"$SIGNING_KEY_PK\",
                        \"access_token_validity\": \"hours=1\"
                        $SKIP_FIELD
                      }")
                    PROVIDER_PK=$(echo "$PROVIDER_RESPONSE" | $JQ -r '.pk // empty')
                    if [ -n "$PROVIDER_PK" ]; then
                      echo "  $APP_NAME: provider created"
                    else
                      echo "  WARN: $APP_NAME provider failed"
                      return 0
                    fi
                  else
                    echo "  $APP_NAME: provider exists"
                  fi

                  # Assign to outpost
                  if [ -n "$OUTPOST_PK" ] && [ -n "$PROVIDER_PK" ]; then
                    CURRENT_PROVIDERS=$($CURL -s "$API/outposts/instances/$OUTPOST_PK/" -H "$AUTH" | $JQ -r '[.providers[]] | map(tostring) | join(",")')
                    if ! echo ",$CURRENT_PROVIDERS," | grep -q ",$PROVIDER_PK,"; then
                      if [ -n "$CURRENT_PROVIDERS" ]; then
                        ALL_PROVIDERS="[$CURRENT_PROVIDERS,$PROVIDER_PK]"
                      else
                        ALL_PROVIDERS="[$PROVIDER_PK]"
                      fi
                      $CURL -s -X PATCH "$API/outposts/instances/$OUTPOST_PK/" -H "$AUTH" -H "Content-Type: application/json" \
                        -d "{\"providers\": $ALL_PROVIDERS}" > /dev/null
                    fi
                  fi

                  # Create application
                  APP_EXISTS=$($CURL -s "$API/core/applications/?slug=$SLUG-fwd" -H "$AUTH" | $JQ -r '.pagination.count')
                  if [ "$APP_EXISTS" = "0" ]; then
                    $CURL -s -X POST "$API/core/applications/" -H "$AUTH" -H "Content-Type: application/json" \
                      -d "{
                        \"name\": \"$APP_NAME (ForwardAuth)\",
                        \"slug\": \"$SLUG-fwd\",
                        \"provider\": $PROVIDER_PK,
                        \"meta_launch_url\": \"$EXTERNAL_HOST\"
                      }" > /dev/null
                    echo "  $APP_NAME: app created"
                  else
                    echo "  $APP_NAME: app exists"
                  fi
                }

                # Arr-stack services (API bypass for external app clients)
                create_forward_auth_app "Sonarr" "sonarr" "https://$(hostname sonarr)" "^/api.*"
                create_forward_auth_app "Sonarr ES" "sonarr-es" "https://$(hostname sonarr-es)" "^/api.*"
                create_forward_auth_app "Radarr" "radarr" "https://$(hostname radarr)" "^/api.*"
                create_forward_auth_app "Radarr ES" "radarr-es" "https://$(hostname radarr-es)" "^/api.*"
                create_forward_auth_app "Prowlarr" "prowlarr" "https://$(hostname prowlarr)" "^/api.*"
                create_forward_auth_app "qBittorrent" "qbittorrent" "https://$(hostname qbit)" "^/api.*"
                create_forward_auth_app "Bazarr" "bazarr" "https://$(hostname bazarr)" "^/api.*"
                create_forward_auth_app "Lidarr" "lidarr" "https://$(hostname lidarr)" "^/api.*"
                create_forward_auth_app "Bookshelf" "bookshelf" "https://$(hostname books)" "^/api.*"

                # Monitoring services (protect all paths)
                create_forward_auth_app "Prometheus" "prometheus" "https://$(hostname prometheus)"
                create_forward_auth_app "Alertmanager" "alertmanager" "https://$(hostname alertmanager)"

                # Infrastructure dashboards
                create_forward_auth_app "Traefik" "traefik" "https://$(hostname traefik)"

                # ============================================
                # SAVE CREDENTIALS
                # ============================================
                AUTHENTIK_URL="https://$(hostname auth)"

                cat <<EOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: authentik-sso-credentials
          namespace: traefik-system
        type: Opaque
        stringData:
          AUTHENTIK_URL: "$AUTHENTIK_URL"
          GRAFANA_CLIENT_ID: "grafana"
          GRAFANA_CLIENT_SECRET: "$GRAFANA_CLIENT_SECRET"
          NEXTCLOUD_CLIENT_ID: "nextcloud"
          NEXTCLOUD_CLIENT_SECRET: "$NEXTCLOUD_CLIENT_SECRET"
          JELLYFIN_CLIENT_ID: "jellyfin"
          JELLYFIN_CLIENT_SECRET: "$JELLYFIN_CLIENT_SECRET"
          JELLYSEERR_CLIENT_ID: "jellyseerr"
          JELLYSEERR_CLIENT_SECRET: "$JELLYSEERR_CLIENT_SECRET"
          IMMICH_CLIENT_ID: "immich"
          IMMICH_CLIENT_SECRET: "$IMMICH_CLIENT_SECRET"
          VAULTWARDEN_CLIENT_ID: "vaultwarden"
          VAULTWARDEN_CLIENT_SECRET: "$VAULTWARDEN_CLIENT_SECRET"
          UPTIME_KUMA_CLIENT_ID: "uptime-kuma"
          UPTIME_KUMA_CLIENT_SECRET: "$UPTIME_KUMA_CLIENT_SECRET"
          HOMARR_CLIENT_ID: "homarr"
          HOMARR_CLIENT_SECRET: "$HOMARR_CLIENT_SECRET"
          KAVITA_CLIENT_ID: "kavita"
          KAVITA_CLIENT_SECRET: "$KAVITA_CLIENT_SECRET"
        EOF

                # Copy to namespaces
                for target_ns in monitoring nextcloud media immich vaultwarden uptime-kuma homarr; do
                  $KUBECTL create namespace $target_ns --dry-run=client -o yaml | $KUBECTL apply -f -
                  $KUBECTL get secret authentik-sso-credentials -n traefik-system -o json | \
                    $JQ 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations)' | \
                    $JQ ".metadata.namespace = \"$target_ns\"" | \
                    $KUBECTL apply -f - 2>/dev/null || true
                done

                print_success "Authentik SSO" \
                  "OIDC providers created for: Grafana, Nextcloud, Jellyfin, Jellyseerr, Immich, Vaultwarden, Homarr, Kavita" \
                  "Credentials stored in K8s secret authentik-sso-credentials (traefik-system + copied to namespaces)" \
                  "Groups: admins, media-admins, media-users, family, monitoring"

                create_marker "${markerFile}"
      '';
    };
  };
}
