{
  k8s,
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  ns = "authentik";
  markerFile = "/var/lib/authentik-google-source-setup-done";
  cfg = serverConfig.authentik.google;
  secretName = "authentik-google-client-secret";
  secretPath = config.age.secrets.${secretName}.path;
  sourceSlug = "google";
  sourceName = "Google";
  authenticationFlow = "default-source-authentication";
  enrollmentFlow = "default-source-enrollment";
  identificationStage = "default-authentication-identification";
  apiPort = "19003";

  configHash = builtins.hashString "sha256" (
    builtins.toJSON {
      inherit (cfg) clientId allowEnrollment;
    }
  );
in
{
  assertions = [
    {
      assertion = cfg.clientId != "";
      message = "authentik.google.clientId must hold the OAuth client id from Google Cloud";
    }
  ];

  age.secrets.${secretName} = {
    file = "${secretsPath}/${secretName}.age";
  };

  systemd.services.authentik-google-source-setup = {
    description = "Add Google as an authentik login source";
    after = [
      "k3s-core.target"
      "authentik-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "authentik-setup.service"
      "authentik-sso-setup.service"
    ];
    wantedBy = [ "k3s-apps.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "authentik-google-source-setup" ''
        ${k8s.libShSource}

        CONFIG_HASH="${configHash}-$(sha256sum ${secretPath} | cut -d' ' -f1)"
        setup_preamble_hash "${markerFile}" "Authentik Google source" "$CONFIG_HASH"
        wait_for_k3s

        API_TOKEN=$(get_secret_value "${ns}" "authentik-api-token" "TOKEN")
        if [ -z "$API_TOKEN" ]; then
          echo "ERROR: no authentik API token in ${ns}/authentik-api-token"
          echo "  authentik-sso-setup creates it; run that first"
          exit 1
        fi

        pkill -f 'port-forward.*${apiPort}' 2>/dev/null || true
        sleep 2
        $KUBECTL port-forward -n ${ns} svc/authentik-server ${apiPort}:80 >/dev/null 2>&1 &
        PF_PID=$!
        trap 'kill $PF_PID 2>/dev/null || true' EXIT

        API="http://localhost:${apiPort}/api/v3"
        AUTH="Authorization: Bearer $API_TOKEN"

        for _ in $(seq 1 30); do
          $CURL -sf "$API/core/applications/" -H "$AUTH" >/dev/null 2>&1 && break
          sleep 5
        done
        if ! $CURL -sf "$API/core/applications/" -H "$AUTH" >/dev/null 2>&1; then
          echo "ERROR: authentik API not reachable or token invalid"
          exit 1
        fi

        AUTHN_FLOW_PK=$($CURL -s "$API/flows/instances/?slug=${authenticationFlow}" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
        if [ -z "$AUTHN_FLOW_PK" ]; then
          echo "ERROR: flow ${authenticationFlow} not found"
          exit 1
        fi

        ENROLLMENT_FLOW_PK=""
        ${lib.optionalString cfg.allowEnrollment ''
          ENROLLMENT_FLOW_PK=$($CURL -s "$API/flows/instances/?slug=${enrollmentFlow}" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
          if [ -z "$ENROLLMENT_FLOW_PK" ]; then
            echo "ERROR: flow ${enrollmentFlow} not found"
            exit 1
          fi
        ''}

        CLIENT_SECRET=$(cat ${secretPath})
        BODY=$($JQ -n \
          --arg name "${sourceName}" \
          --arg slug "${sourceSlug}" \
          --arg key "${cfg.clientId}" \
          --arg secret "$CLIENT_SECRET" \
          --arg authn "$AUTHN_FLOW_PK" \
          --arg enroll "$ENROLLMENT_FLOW_PK" \
          '{
            name: $name,
            slug: $slug,
            provider_type: "google",
            consumer_key: $key,
            consumer_secret: $secret,
            enabled: true,
            promoted: true,
            user_matching_mode: "email_link",
            authentication_flow: $authn,
            enrollment_flow: (if $enroll == "" then null else $enroll end)
          }')

        SOURCE_PK=$($CURL -s "$API/sources/oauth/?slug=${sourceSlug}" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
        if [ -z "$SOURCE_PK" ]; then
          echo "Creating the Google source..."
          RESPONSE=$($CURL -s -X POST "$API/sources/oauth/" -H "$AUTH" -H "Content-Type: application/json" -d "$BODY")
        else
          echo "Updating the Google source ($SOURCE_PK)..."
          RESPONSE=$($CURL -s -X PATCH "$API/sources/oauth/${sourceSlug}/" -H "$AUTH" -H "Content-Type: application/json" -d "$BODY")
        fi
        SOURCE_PK=$(echo "$RESPONSE" | $JQ -r '.pk // empty')
        if [ -z "$SOURCE_PK" ]; then
          echo "ERROR: authentik refused the source:"
          echo "$RESPONSE" | $JQ -r '.. | strings' | head -20
          exit 1
        fi

        STAGE=$($CURL -s -G "$API/stages/identification/" --data-urlencode "search=${identificationStage}" -H "$AUTH" \
          | $JQ -c --arg n "${identificationStage}" '.results[] | select(.name == $n)')
        STAGE_PK=$(echo "$STAGE" | $JQ -r '.pk // empty')
        if [ -z "$STAGE_PK" ]; then
          echo "ERROR: stage ${identificationStage} not found"
          exit 1
        fi

        SOURCES=$(echo "$STAGE" | $JQ -c --arg s "$SOURCE_PK" '(.sources + [$s]) | unique')
        RESPONSE=$($CURL -s -X PATCH "$API/stages/identification/$STAGE_PK/" -H "$AUTH" -H "Content-Type: application/json" \
          -d "{\"sources\": $SOURCES, \"show_source_labels\": true}")
        if [ "$(echo "$RESPONSE" | $JQ -r '.pk // empty')" != "$STAGE_PK" ]; then
          echo "ERROR: authentik refused the stage update:"
          echo "$RESPONSE" | $JQ -r '.. | strings' | head -20
          exit 1
        fi

        create_marker "${markerFile}" "$CONFIG_HASH"
        print_success "Authentik Google source" \
          "Source ${sourceSlug} linked to existing users by email" \
          "Enrollment of unknown accounts: ${if cfg.allowEnrollment then "allowed" else "denied"}" \
          "Shown on the ${identificationStage} stage"
      '';
    };
  };
}
