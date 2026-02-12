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
  markerFile = "/var/lib/authentik-nas-apps-done";
  domain = "${serverConfig.subdomain}.${serverConfig.domain}";

  # Detect old single-NAS config vs new multi-NAS config
  rawNasConfig = serverConfig.nas or { };
  isOldFormat = rawNasConfig ? ip;

  # Normalize to new format
  nasConfig =
    if isOldFormat then
      {
        nas1 = rawNasConfig // {
          hostname = "nas";
          description = "NAS (migrated from old config)";
        };
      }
    else
      rawNasConfig;

  # Filter only enabled NAS
  enabledNAS = lib.filterAttrs (name: cfg: cfg.enabled or false) nasConfig;

  # Check if any NAS is enabled
  anyNasEnabled = (builtins.length (builtins.attrNames enabledNAS)) > 0;

  # Generate friendly app name (NAS1 -> NAS 1)
  generateAppName =
    nasName: serviceName:
    let
      # Extract number from nasN or use full name
      num = lib.removePrefix "nas" nasName;
      nasLabel = if num != nasName then "NAS ${num}" else nasName;
    in
    "${nasLabel} ${serviceName}";

  # Generate slug (nas1-cockpit)
  generateSlug = nasName: serviceName: "${nasName}-${lib.toLower serviceName}";

  # Generate external host URL
  generateExternalHost =
    nasCfg: serviceName:
    let
      hostname =
        if serviceName == "Cockpit" then
          nasCfg.hostname or "nas"
        else
          "files${lib.removePrefix "nas" (nasCfg.hostname or "nas")}";
    in
    "https://${hostname}.${domain}";

  # Generate internal host URL
  generateInternalHost =
    nasName: serviceName: port:
    "http://${nasName}-${lib.toLower serviceName}.nas.svc.cluster.local:${toString port}";

  # Generate create_proxy_app calls for all NAS
  generateProxyAppCalls = lib.concatStringsSep "\n\n" (
    lib.flatten (
      lib.mapAttrsToList (nasName: nasCfg: [
        # Cockpit app
        ''
          echo "Creating application: ${generateAppName nasName "Cockpit"}..."
          create_proxy_app \
            "${generateAppName nasName "Cockpit"}" \
            "${generateSlug nasName "cockpit"}" \
            "${generateExternalHost nasCfg "Cockpit"}" \
            "${generateInternalHost nasName "cockpit" (nasCfg.cockpitPort or 9090)}"
        ''
        # FileBrowser app
        ''
          echo "Creating application: ${generateAppName nasName "Files"}..."
          create_proxy_app \
            "${generateAppName nasName "Files"}" \
            "${generateSlug nasName "files"}" \
            "${generateExternalHost nasCfg "Files"}" \
            "${generateInternalHost nasName "filebrowser" (nasCfg.fileBrowserPort or 8080)}"
        ''
      ]) enabledNAS
    )
  );

  # Build success notes
  successNotes = [
    "Applications created for ${toString (builtins.length (builtins.attrNames enabledNAS))} NAS:"
  ]
  ++ (lib.flatten (
    lib.mapAttrsToList (nasName: nasCfg: [
      "  - ${generateAppName nasName "Cockpit"} (slug: ${generateSlug nasName "cockpit"})"
      "  - ${generateAppName nasName "Files"} (slug: ${generateSlug nasName "files"})"
    ]) enabledNAS
  ))
  ++ [
    "Proxy providers created for ForwardAuth"
    "Assigned to proxy outpost"
    "ForwardAuth middleware: authentik-forward-auth (traefik-system)"
  ];
in
{
  config = lib.mkIf anyNasEnabled {
    systemd.services.authentik-nas-apps-setup = {
      description = "Setup Authentik applications for NAS services";
      # After media
      after = [
        "k3s-media.target"
        "authentik-sso-setup.service"
      ];
      requires = [ "k3s-media.target" ];
      wants = [ "authentik-sso-setup.service" ];
      wantedBy = [ "k3s-extras.target" ];
      before = [ "k3s-extras.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "authentik-nas-apps-setup" ''
                    ${k8s.libShSource}

                    setup_preamble "${markerFile}" "Authentik NAS Apps"
                    wait_for_k3s

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

                    # Read API token (bootstrap token doesn't work as bearer after initial setup)
                    API_TOKEN=$(get_secret_value "${ns}" "authentik-api-token" "TOKEN")
                    if [ -z "$API_TOKEN" ]; then
                      echo "ERROR: Authentik API token not found in K8s secret authentik-api-token"
                      echo "Ensure authentik-setup has run successfully"
                      exit 1
                    fi

                    # Port-forward to Authentik API
                    pkill -f 'port-forward.*authentik-server' 2>/dev/null || true
                    sleep 2
                    $KUBECTL port-forward -n ${ns} svc/authentik-server 19000:80 &
                    PF_PID=$!
                    sleep 5

                    API="http://localhost:19000/api/v3"
                    AUTH="Authorization: Bearer $API_TOKEN"

                    # Wait for API to respond
                    echo "Waiting for Authentik API..."
                    for i in $(seq 1 30); do
                      if $CURL -sf "$API/core/applications/" -H "$AUTH" &>/dev/null; then
                        echo "API available"
                        break
                      fi
                      echo "Waiting for API... ($i/30)"
                      sleep 5
                    done

                    if ! $CURL -sf "$API/core/applications/" -H "$AUTH" &>/dev/null; then
                      kill $PF_PID 2>/dev/null || true
                      echo "ERROR: Authentik API not available"
                      exit 1
                    fi

                    # ============================================
                    # GET REQUIRED RESOURCES
                    # ============================================

                    # Get authorization flow PK
                    AUTH_FLOW_PK=$($CURL -s "$API/flows/instances/?slug=default-provider-authorization-implicit-consent" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                    if [ -z "$AUTH_FLOW_PK" ]; then
                      AUTH_FLOW_PK=$($CURL -s "$API/flows/instances/" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                    fi
                    echo "Authorization flow: $AUTH_FLOW_PK"

                    # Get invalidation flow PK
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

                    if [ -z "$AUTH_FLOW_PK" ] || [ -z "$SIGNING_KEY_PK" ]; then
                      kill $PF_PID 2>/dev/null || true
                      echo "ERROR: Flow or signing key not found"
                      exit 1
                    fi

                    # ============================================
                    # GET OR CREATE PROXY OUTPOST
                    # ============================================

                    echo "Looking for existing proxy outpost..."
                    OUTPOST_PK=$($CURL -s "$API/outposts/instances/?type=proxy" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

                    if [ -z "$OUTPOST_PK" ]; then
                      echo "Creating proxy outpost..."
                      # Get embedded outpost service connection (default)
                      SERVICE_CONNECTION_PK=$($CURL -s "$API/outposts/service_connections/all/?name=authentik%20Embedded%20Outpost" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                      if [ -z "$SERVICE_CONNECTION_PK" ]; then
                        # Fallback to first available
                        SERVICE_CONNECTION_PK=$($CURL -s "$API/outposts/service_connections/all/" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                      fi

                      OUTPOST_RESPONSE=$($CURL -s -X POST "$API/outposts/instances/" -H "$AUTH" -H "Content-Type: application/json" \
                        -d "{
                          \"name\": \"NAS Proxy Outpost\",
                          \"type\": \"proxy\",
                          \"service_connection\": \"$SERVICE_CONNECTION_PK\",
                          \"config\": {
                            \"authentik_host\": \"https://auth.${domain}/\",
                            \"log_level\": \"info\"
                          }
                        }")
                      OUTPOST_PK=$(echo "$OUTPOST_RESPONSE" | $JQ -r '.pk // empty')
                      if [ -n "$OUTPOST_PK" ]; then
                        echo "Outpost created: $OUTPOST_PK"
                      else
                        echo "ERROR creating outpost: $OUTPOST_RESPONSE"
                      fi
                    else
                      echo "Existing outpost: $OUTPOST_PK"
                      # Ensure authentik_host is set (embedded outpost defaults to empty)
                      CURRENT_HOST=$($CURL -s "$API/outposts/instances/$OUTPOST_PK/" -H "$AUTH" | $JQ -r '.config.authentik_host // empty')
                      if [ -z "$CURRENT_HOST" ]; then
                        echo "Setting authentik_host on outpost..."
                        $CURL -s -X PATCH "$API/outposts/instances/$OUTPOST_PK/" -H "$AUTH" -H "Content-Type: application/json" \
                          -d "{\"config\": {\"authentik_host\": \"https://auth.${domain}/\"}}" > /dev/null
                      fi
                    fi

                    # ============================================
                    # CREATE PROXY PROVIDERS AND APPLICATIONS
                    # ============================================

                    create_proxy_app() {
                      local APP_NAME="$1"
                      local SLUG="$2"
                      local EXTERNAL_HOST="$3"
                      local INTERNAL_HOST="$4"

                      # Check if provider already exists
                      SEARCH_QUERY=$(echo "$APP_NAME Provider" | sed 's/ /+/g')
                      PROVIDER_PK=$($CURL -s "$API/providers/proxy/?search=$SEARCH_QUERY" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

                      if [ -z "$PROVIDER_PK" ]; then
                        # Create provider
                        PROVIDER_RESPONSE=$($CURL -s -X POST "$API/providers/proxy/" -H "$AUTH" -H "Content-Type: application/json" \
                          -d "{
                            \"name\": \"$APP_NAME Provider\",
                            \"authorization_flow\": \"$AUTH_FLOW_PK\",
                            \"invalidation_flow\": \"$INVALIDATION_FLOW_PK\",
                            \"mode\": \"forward_single\",
                            \"external_host\": \"$EXTERNAL_HOST\",
                            \"internal_host\": \"$INTERNAL_HOST\",
                            \"certificate\": \"$SIGNING_KEY_PK\",
                            \"skip_path_regex\": \"^/api.*\",
                            \"access_token_validity\": \"hours=1\"
                          }")
                        PROVIDER_PK=$(echo "$PROVIDER_RESPONSE" | $JQ -r '.pk // empty')
                        if [ -n "$PROVIDER_PK" ]; then
                          echo "$APP_NAME Provider: created (pk=$PROVIDER_PK)"
                        else
                          echo "ERROR: $APP_NAME Provider: $(echo "$PROVIDER_RESPONSE" | $JQ -r '.' 2>/dev/null || echo "$PROVIDER_RESPONSE")"
                          return 1
                        fi
                      else
                        echo "$APP_NAME Provider: exists (pk=$PROVIDER_PK)"
                      fi

                      # Assign provider to outpost
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
                          echo "$APP_NAME Provider: assigned to outpost"
                        else
                          echo "$APP_NAME Provider: already in outpost"
                        fi
                      fi

                      # Check if application already exists
                      APP_EXISTS=$($CURL -s "$API/core/applications/?slug=$SLUG" -H "$AUTH" | $JQ -r '.pagination.count')
                      if [ "$APP_EXISTS" = "0" ]; then
                        $CURL -s -X POST "$API/core/applications/" -H "$AUTH" -H "Content-Type: application/json" \
                          -d "{
                            \"name\": \"$APP_NAME\",
                            \"slug\": \"$SLUG\",
                            \"provider\": $PROVIDER_PK,
                            \"meta_launch_url\": \"$EXTERNAL_HOST\"
                          }" > /dev/null
                        echo "$APP_NAME App: created"
                      else
                        $CURL -s -X PATCH "$API/core/applications/?slug=$SLUG" -H "$AUTH" -H "Content-Type: application/json" \
                          -d "{\"provider\": $PROVIDER_PK}" > /dev/null 2>&1 || true
                        echo "$APP_NAME App: exists"
                      fi
                    }

                    echo ""
                    echo "=========================================="
                    echo "Creating applications for multiple NAS"
                    echo "=========================================="
                    echo ""

                    ${generateProxyAppCalls}

                    kill $PF_PID 2>/dev/null || true

                    # ============================================
                    # CREATE FORWARDAUTH MIDDLEWARE
                    # ============================================

                    # Only create if it doesn't exist (might be created by other services)
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

                    print_success "Authentik NAS Apps" \
                      ${lib.concatMapStringsSep " " (n: "\"${n}\"") successNotes}

                    create_marker "${markerFile}"
        '';
      };
    };
  };
}
