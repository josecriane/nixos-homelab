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
  markerFile = "/var/lib/kavita-setup-done";
in
{
  systemd.services.kavita-setup = {
    description = "Setup Kavita manga/comics server";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "nfs-storage-setup.service"
      "authentik-sso-setup.service"
    ];
    # TIER 4: Media
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "kavita-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Kavita"

        wait_for_k3s
        setup_namespace "${ns}"
        wait_for_shared_data "${ns}"

        # PVC for config (2Gi - Kavita stores cover images in config dir)
        create_pvc "kavita-config" "${ns}" "2Gi"

        # Deployment - uses shared-data with TRaSH Guides structure
        ${k8s.createLinuxServerDeployment {
          name = "kavita";
          namespace = ns;
          image = "lscr.io/linuxserver/kavita:0.8.9";
          port = 5000;
          configPVC = "kavita-config";
          extraVolumeMounts = [
            "- name: data\n          mountPath: /data"
          ];
          extraVolumes = [
            "- name: data\n        persistentVolumeClaim:\n          claimName: shared-data"
          ];
        }}

        wait_for_pod "${ns}" "app=kavita" 180

        # Create media directories for manga and comics
        $KUBECTL exec -n ${ns} deploy/kavita -- mkdir -p /data/media/manga /data/media/comics 2>/dev/null || true

        # ============================================
        # API-based admin setup
        # ============================================

        # Reuse existing admin password or generate new one
        ADMIN_PASS=$(get_secret_value "${ns}" "kavita-credentials" "ADMIN_PASSWORD")
        if [ -z "$ADMIN_PASS" ]; then
          ADMIN_PASS=$(generate_password 16)
          echo "Generated Kavita admin password"
        fi

        # Port-forward to Kavita
        pkill -f 'port-forward.*kavita.*15000' 2>/dev/null || true
        sleep 2
        $KUBECTL port-forward -n ${ns} svc/kavita 15000:5000 &
        PF_PID=$!
        trap "kill $PF_PID 2>/dev/null || true" EXIT
        sleep 5

        KAVITA_API="http://localhost:15000/api"

        # Wait for API ready
        echo "Waiting for Kavita API..."
        API_READY=false
        for i in $(seq 1 60); do
          if $CURL -sf "$KAVITA_API/health" &>/dev/null; then
            echo "Kavita API available"
            API_READY=true
            break
          fi
          # Restart port-forward if it died
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

        # Try login first (works on re-runs when admin already exists)
        echo "Logging into Kavita..."
        LOGIN_RESPONSE=$($CURL -s -X POST "$KAVITA_API/Account/login" \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null || echo "")
        TOKEN=$(echo "$LOGIN_RESPONSE" | $JQ -r '.token // empty' 2>/dev/null || echo "")

        if [ -z "$TOKEN" ]; then
          # First run, register admin user
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

          # Check existing libraries
          EXISTING_LIBS=$($CURL -s "$KAVITA_API/Library" -H "$AUTH" 2>/dev/null || echo "[]")
          EXISTING_COUNT=$(echo "$EXISTING_LIBS" | $JQ 'length' 2>/dev/null || echo "0")

          if [ "$EXISTING_COUNT" = "0" ] || [ "$EXISTING_COUNT" = "" ]; then
            echo "Creating libraries..."

            # type 2 = Manga
            $CURL -s -X POST "$KAVITA_API/Library" \
              -H "$AUTH" -H "Content-Type: application/json" \
              -d '{"name":"Manga","type":2,"folders":["/data/media/manga"]}' > /dev/null 2>&1
            echo "  Library: Manga"

            # type 1 = Comic
            $CURL -s -X POST "$KAVITA_API/Library" \
              -H "$AUTH" -H "Content-Type: application/json" \
              -d '{"name":"Comics","type":1,"folders":["/data/media/comics"]}' > /dev/null 2>&1
            echo "  Library: Comics"

            # type 0 = Book (shared with Bookshelf)
            $CURL -s -X POST "$KAVITA_API/Library" \
              -H "$AUTH" -H "Content-Type: application/json" \
              -d '{"name":"Books","type":0,"folders":["/data/media/books"]}' > /dev/null 2>&1
            echo "  Library: Books"
          else
            echo "Libraries already exist ($EXISTING_COUNT)"
          fi

          # Save credentials to K8s secret
          store_credentials "${ns}" "kavita-credentials" \
            "ADMIN_USER=admin" "ADMIN_PASSWORD=$ADMIN_PASS" "API_KEY=$API_KEY"

          # ============================================
          # OIDC Configuration (Authentik SSO)
          # ============================================
          KAVITA_CLIENT_SECRET=$(get_secret_value "${ns}" "authentik-sso-credentials" "KAVITA_CLIENT_SECRET")
          AUTHENTIK_URL=$(get_secret_value "${ns}" "authentik-sso-credentials" "AUTHENTIK_URL")
          if [ -n "$KAVITA_CLIENT_SECRET" ] || [ -n "$AUTHENTIK_URL" ]; then

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
                  echo "OIDC configured successfully"
                else
                  echo "WARN: Could not configure OIDC via API, configure manually in Kavita UI"
                fi
              fi
            else
              echo "WARN: SSO credentials incomplete, skipping OIDC"
            fi
          else
            echo "SSO credentials not available, skipping OIDC"
          fi
        fi

        # IngressRoute (OIDC handles auth)
        create_ingress_route "kavita" "${ns}" "$(hostname kavita)" "kavita" "5000"

        print_success "Kavita" \
          "URLs:" \
          "  URL: https://$(hostname kavita)" \
          "" \
          "Credentials stored in K8s secret kavita-credentials" \
          "Libraries: Manga, Comics, Books" \
          "OIDC: auto-configured via Authentik"

        create_marker "${markerFile}"
      '';
    };
  };
}
