# Kavita - manga/comics/books reader with Authentik OIDC.
# Declared via bjw-s/app-template Helm library chart. Post-install
# configuration (admin user, libraries, OIDC via /api/Settings) runs in a
# separate systemd service so Helm reconciliation stays idempotent.
{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "media";
  configMarkerFile = "/var/lib/kavita-config-setup-done";

  release = k8s.createHelmRelease {
    name = "kavita";
    namespace = ns;
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "kavita";
    ingress = {
      host = "kavita";
      service = "kavita";
      port = 5000;
    };
  };
in
lib.recursiveUpdate release {
  systemd.services.kavita-setup = {
    after = (release.systemd.services.kavita-setup.after or [ ]) ++ [
      "nfs-storage-setup.service"
    ];
    wants = [
      "nfs-storage-setup.service"
    ];
  };

  systemd.services.kavita-config-setup = {
    description = "Configure Kavita admin/libraries/OIDC";
    after = [
      "k3s-apps.target"
      "kavita-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [
      "kavita-setup.service"
      "authentik-sso-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "kavita-config-setup" ''
        ${k8s.libShSource}
        setup_preamble "${configMarkerFile}" "Kavita config"

        wait_for_k3s

        # Skip config if kavita is paused (replicas=0): would spin waiting
        # for a pod that will never come up.
        if [ "$($KUBECTL get deploy -n ${ns} kavita -o jsonpath='{.spec.replicas}' 2>/dev/null)" = "0" ]; then
          echo "Kavita is paused (replicas=0), skipping config"
          create_marker "${configMarkerFile}"
          exit 0
        fi

        wait_for_deployment "${ns}" "kavita" 180

        $KUBECTL exec -n ${ns} deploy/kavita -- mkdir -p /data/media/manga /data/media/comics 2>/dev/null || true

        ADMIN_PASS=$(get_secret_value "${ns}" "kavita-credentials" "ADMIN_PASSWORD")
        if [ -z "$ADMIN_PASS" ]; then
          ADMIN_PASS=$(generate_password 16)
          echo "Generated Kavita admin password"
        fi

        pkill -f 'port-forward.*kavita.*15000' 2>/dev/null || true
        sleep 2
        $KUBECTL port-forward -n ${ns} svc/kavita 15000:5000 &
        PF_PID=$!
        trap "kill $PF_PID 2>/dev/null || true" EXIT
        sleep 5

        KAVITA_API="http://localhost:15000/api"

        echo "Waiting for Kavita API..."
        API_READY=false
        for i in $(seq 1 60); do
          if $CURL -sf "$KAVITA_API/health" &>/dev/null; then
            echo "Kavita API available"
            API_READY=true
            break
          fi
          if ! kill -0 $PF_PID 2>/dev/null; then
            $KUBECTL port-forward -n ${ns} svc/kavita 15000:5000 &
            PF_PID=$!
            sleep 3
          fi
          echo "Waiting for API... ($i/60)"
          sleep 5
        done

        if [ "$API_READY" != "true" ]; then
          echo "ERROR: Kavita API not available"
          exit 1
        fi

        echo "Logging into Kavita..."
        LOGIN_RESPONSE=$($CURL -s -X POST "$KAVITA_API/Account/login" \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null || echo "")
        TOKEN=$(echo "$LOGIN_RESPONSE" | $JQ -r '.token // empty' 2>/dev/null || echo "")

        if [ -z "$TOKEN" ]; then
          echo "Admin not found, registering..."
          REGISTER_RESPONSE=$($CURL -s -X POST "$KAVITA_API/Account/register" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\",\"email\":\"\"}" 2>/dev/null || echo "")
          TOKEN=$(echo "$REGISTER_RESPONSE" | $JQ -r '.token // empty' 2>/dev/null || echo "")
          if [ -n "$TOKEN" ]; then
            echo "Admin registered successfully"
          fi
        else
          echo "Admin login OK"
        fi

        if [ -z "$TOKEN" ]; then
          echo "WARN: Could not obtain Kavita token, skipping library configuration"
        else
          API_KEY=$(echo "''${LOGIN_RESPONSE}''${REGISTER_RESPONSE}" | $JQ -r '.apiKey // empty' 2>/dev/null || echo "" | head -1)
          AUTH="Authorization: Bearer $TOKEN"

          EXISTING_LIBS=$($CURL -s "$KAVITA_API/Library" -H "$AUTH" 2>/dev/null || echo "[]")
          EXISTING_COUNT=$(echo "$EXISTING_LIBS" | $JQ 'length' 2>/dev/null || echo "0")

          if [ "$EXISTING_COUNT" = "0" ] || [ "$EXISTING_COUNT" = "" ]; then
            echo "Creating libraries..."
            $CURL -s -X POST "$KAVITA_API/Library" \
              -H "$AUTH" -H "Content-Type: application/json" \
              -d '{"name":"Manga","type":2,"folders":["/data/media/manga"]}' > /dev/null 2>&1
            echo "  Library: Manga"
            $CURL -s -X POST "$KAVITA_API/Library" \
              -H "$AUTH" -H "Content-Type: application/json" \
              -d '{"name":"Comics","type":1,"folders":["/data/media/comics"]}' > /dev/null 2>&1
            echo "  Library: Comics"
            $CURL -s -X POST "$KAVITA_API/Library" \
              -H "$AUTH" -H "Content-Type: application/json" \
              -d '{"name":"Books","type":0,"folders":["/data/media/books"]}' > /dev/null 2>&1
            echo "  Library: Books"
          else
            echo "Libraries already exist ($EXISTING_COUNT)"
          fi

          store_credentials "${ns}" "kavita-credentials" \
            "ADMIN_USER=admin" "ADMIN_PASSWORD=$ADMIN_PASS" "API_KEY=$API_KEY"

          KAVITA_CLIENT_SECRET=$(get_secret_value "${ns}" "authentik-sso-credentials" "KAVITA_CLIENT_SECRET")
          AUTHENTIK_URL=$(get_secret_value "${ns}" "authentik-sso-credentials" "AUTHENTIK_URL")
          if [ -n "$KAVITA_CLIENT_SECRET" ] && [ -n "$AUTHENTIK_URL" ]; then
            echo "Configuring OIDC..."

            SETTINGS=$($CURL -s "$KAVITA_API/Settings" -H "$AUTH" 2>/dev/null || echo "")
            OIDC_ENABLED=$(echo "$SETTINGS" | $JQ -r '.oidcConfig.enabled' 2>/dev/null)

            if [ "$OIDC_ENABLED" = "true" ]; then
              echo "OIDC already configured"
            else
              AUTHORITY="$AUTHENTIK_URL/application/o/kavita/"
              UPDATED=$(echo "$SETTINGS" | $JQ \
                --arg csec "$KAVITA_CLIENT_SECRET" \
                --arg auth "$AUTHORITY" \
                '.oidcConfig.enabled = true | .oidcConfig.clientId = "kavita" | .oidcConfig.secret = $csec | .oidcConfig.authority = $auth | .oidcConfig.requireVerifiedEmail = false | .oidcConfig.provisionAccounts = true | .oidcConfig.defaultRoles = ["Login", "Pleb"] | .oidcConfig.rolesClaim = "kavita_roles" | .oidcConfig.customScopes = ["kavita_roles"]')

              RESULT=$($CURL -s -X POST "$KAVITA_API/Settings" \
                -H "$AUTH" -H "Content-Type: application/json" \
                -d "$UPDATED" 2>/dev/null || echo "")

              if echo "$RESULT" | $JQ -e '.' &>/dev/null 2>&1; then
                echo "OIDC configured successfully, restarting pod..."
                kill $PF_PID 2>/dev/null || true
                $KUBECTL rollout restart deploy/kavita -n ${ns}
                wait_for_deployment "${ns}" "kavita" 120
              else
                echo "WARN: Could not configure OIDC via API, configure manually in Kavita UI"
              fi
            fi
          else
            echo "SSO credentials not available, skipping OIDC"
          fi
        fi

        print_success "Kavita config" \
          "URL: https://$(hostname kavita)" \
          "" \
          "Credentials stored in K8s secret kavita-credentials" \
          "Libraries: Manga, Comics, Books" \
          "OIDC: auto-configured via Authentik"

        create_marker "${configMarkerFile}"
      '';
    };
  };
}
