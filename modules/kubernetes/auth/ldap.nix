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
  markerFile = "/var/lib/authentik-ldap-done";
  domain = "${serverConfig.subdomain}.${serverConfig.domain}";

  # Check if LDAP is enabled (used by Syncthing and other services)
  ldapEnabled = serverConfig.authentik.ldap.enable or false;
  ldapIP = serverConfig.authentik.ldap.ip or serverConfig.traefikIP;
in
{
  config = lib.mkIf ldapEnabled {
    systemd.services.authentik-ldap-setup = {
      description = "Setup Authentik LDAP Outpost";
      # After core
      after = [
        "k3s-core.target"
        "authentik-setup.service"
      ];
      requires = [ "k3s-core.target" ];
      wants = [ "authentik-setup.service" ];
      wantedBy = [ "k3s-extras.target" ];
      before = [ "k3s-extras.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "authentik-ldap-setup" ''
                    ${k8s.libShSource}

                    setup_preamble "${markerFile}" "Authentik LDAP"
                    wait_for_k3s

                    # Wait for Authentik to be ready
                    echo "Waiting for Authentik..."
                    for i in $(seq 1 90); do
                      if $KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=authentik -l app.kubernetes.io/component=server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
                        break
                      fi
                      sleep 10
                    done

                    # Read API token (bootstrap token doesn't work as bearer after initial setup)
                    API_TOKEN=$(get_secret_value "${ns}" "authentik-api-token" "TOKEN")
                    if [ -z "$API_TOKEN" ]; then
                      echo "ERROR: Authentik API token not found in K8s secret authentik-api-token"
                      echo "Ensure authentik-setup has run successfully"
                      exit 1
                    fi

                    # Port-forward to Authentik API
                    pkill -f 'port-forward.*authentik-server.*19001' 2>/dev/null || true
                    sleep 2
                    $KUBECTL port-forward -n ${ns} svc/authentik-server 19001:80 &
                    PF_PID=$!
                    sleep 5

                    API="http://localhost:19001/api/v3"
                    AUTH="Authorization: Bearer $API_TOKEN"

                    # Wait for API
                    for i in $(seq 1 30); do
                      if $CURL -sf "$API/core/applications/" -H "$AUTH" &>/dev/null; then
                        break
                      fi
                      sleep 5
                    done

                    # ============================================
                    # CREATE LDAP PROVIDER
                    # ============================================

                    echo "Configuring LDAP Provider..."

                    # Get authentication flow (the LDAP outpost uses authorization_flow for bind,
                    # so both fields must point to a flow with authentication=none and full
                    # auth stages: identification, password, user-login)
                    AUTHN_FLOW_PK=$($CURL -s "$API/flows/instances/?slug=default-authentication-flow" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
                    if [ -z "$AUTHN_FLOW_PK" ]; then
                      echo "ERROR: default-authentication-flow not found"
                      exit 1
                    fi

                    # Get invalidation flow (required by newer Authentik versions)
                    INVALIDATION_FLOW_PK=$($CURL -s "$API/flows/instances/?slug=default-provider-invalidation-flow" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

                    # Get signing key
                    SIGNING_KEY_PK=$($CURL -s "$API/crypto/certificatekeypairs/" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

                    # Check if LDAP provider exists
                    LDAP_PROVIDER_PK=$($CURL -s "$API/providers/ldap/?search=NAS%20LDAP" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

                    if [ -z "$LDAP_PROVIDER_PK" ]; then
                      echo "Creating LDAP Provider..."
                      LDAP_RESPONSE=$($CURL -s -X POST "$API/providers/ldap/" -H "$AUTH" -H "Content-Type: application/json" \
                        -d "{
                          \"name\": \"NAS LDAP Provider\",
                          \"authentication_flow\": \"$AUTHN_FLOW_PK\",
                          \"authorization_flow\": \"$AUTHN_FLOW_PK\",
                          \"invalidation_flow\": \"$INVALIDATION_FLOW_PK\",
                          \"base_dn\": \"dc=nas,dc=local\",
                          \"search_group\": null,
                          \"certificate\": \"$SIGNING_KEY_PK\",
                          \"bind_mode\": \"direct\",
                          \"search_mode\": \"direct\"
                        }")
                      LDAP_PROVIDER_PK=$(echo "$LDAP_RESPONSE" | $JQ -r '.pk // empty')
                      if [ -n "$LDAP_PROVIDER_PK" ]; then
                        echo "LDAP Provider created: $LDAP_PROVIDER_PK"
                      else
                        echo "ERROR: $LDAP_RESPONSE"
                      fi
                    else
                      echo "LDAP Provider exists: $LDAP_PROVIDER_PK"
                      # Ensure flows are correct (outpost uses authorization_flow for LDAP bind)
                      $CURL -s -X PATCH "$API/providers/ldap/$LDAP_PROVIDER_PK/" -H "$AUTH" -H "Content-Type: application/json" \
                        -d "{\"authentication_flow\": \"$AUTHN_FLOW_PK\", \"authorization_flow\": \"$AUTHN_FLOW_PK\"}" > /dev/null
                    fi

                    # ============================================
                    # CREATE LDAP APPLICATION
                    # ============================================

                    APP_EXISTS=$($CURL -s "$API/core/applications/?slug=nas-ldap" -H "$AUTH" | $JQ -r '.pagination.count')
                    if [ "$APP_EXISTS" = "0" ]; then
                      $CURL -s -X POST "$API/core/applications/" -H "$AUTH" -H "Content-Type: application/json" \
                        -d "{
                          \"name\": \"NAS LDAP\",
                          \"slug\": \"nas-ldap\",
                          \"provider\": $LDAP_PROVIDER_PK
                        }" > /dev/null
                      echo "LDAP Application created"
                    else
                      echo "LDAP Application exists"
                    fi

                    # ============================================
                    # CREATE LDAP OUTPOST
                    # ============================================

                    # Find existing LDAP outpost (skip embedded outpost which has no service_connection)
                    LDAP_OUTPOST_PK=$($CURL -s "$API/outposts/instances/?type=ldap" -H "$AUTH" | $JQ -r '[.results[] | select(.service_connection != null)][0].pk // empty')

                    if [ -z "$LDAP_OUTPOST_PK" ]; then
                      echo "Creating LDAP Outpost..."
                      SERVICE_CONNECTION_PK=$($CURL -s "$API/outposts/service_connections/all/" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

                      OUTPOST_RESPONSE=$($CURL -s -X POST "$API/outposts/instances/" -H "$AUTH" -H "Content-Type: application/json" \
                        -d "{
                          \"name\": \"NAS LDAP Outpost\",
                          \"type\": \"ldap\",
                          \"service_connection\": \"$SERVICE_CONNECTION_PK\",
                          \"providers\": [$LDAP_PROVIDER_PK],
                          \"config\": {
                            \"authentik_host\": \"https://auth.${domain}/\",
                            \"log_level\": \"info\"
                          }
                        }")
                      LDAP_OUTPOST_PK=$(echo "$OUTPOST_RESPONSE" | $JQ -r '.pk // empty')
                      if [ -n "$LDAP_OUTPOST_PK" ]; then
                        echo "LDAP Outpost created: $LDAP_OUTPOST_PK"
                      else
                        echo "ERROR: $OUTPOST_RESPONSE"
                      fi
                    else
                      echo "LDAP Outpost exists: $LDAP_OUTPOST_PK"
                      # Ensure provider is assigned
                      $CURL -s -X PATCH "$API/outposts/instances/$LDAP_OUTPOST_PK/" -H "$AUTH" -H "Content-Type: application/json" \
                        -d "{\"providers\": [$LDAP_PROVIDER_PK]}" > /dev/null
                    fi

                    kill $PF_PID 2>/dev/null || true

                    # ============================================
                    # DEPLOY LDAP OUTPOST SERVICE
                    # ============================================

                    echo "Deploying LDAP Outpost Service..."

                    cat <<EOF | $KUBECTL apply -f -
          ---
          apiVersion: v1
          kind: Service
          metadata:
            name: authentik-ldap
            namespace: ${ns}
            annotations:
              metallb.universe.tf/loadBalancerIPs: "${ldapIP}"
          spec:
            type: LoadBalancer
            ports:
              - name: ldap
                port: 389
                targetPort: 3389
                protocol: TCP
              - name: ldaps
                port: 636
                targetPort: 6636
                protocol: TCP
            selector:
              goauthentik.io/outpost-type: ldap
          EOF

                    echo ""
                    echo "=========================================="
                    echo "Authentik LDAP Outpost configured"
                    echo "=========================================="
                    echo ""
                    echo "  LDAP Server: ${ldapIP}:389"
                    echo "  LDAPS Server: ${ldapIP}:636"
                    echo "  Base DN: dc=nas,dc=local"
                    echo ""
                    echo "  Bind DN format:"
                    echo "    cn=<user>,ou=users,dc=nas,dc=local"
                    echo ""

                    create_marker "${markerFile}"
        '';
      };
    };
  };
}
