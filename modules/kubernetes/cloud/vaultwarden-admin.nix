{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "vaultwarden";
  markerFile = "/var/lib/vaultwarden-admin-setup-done";
  credSecretName = "vaultwarden-admin-credentials";
  adminEmail = serverConfig.authentik.adminEmail;

  python = pkgs.python3.withPackages (ps: [ ps.cryptography ]);

  vaultwardenAdminScript = ./scripts/vaultwarden-admin.py;
in
{
  age.secrets.vaultwarden-admin-password = {
    file = "${secretsPath}/vaultwarden-admin-password.age";
  };

  systemd.services.vaultwarden-admin-setup = {
    description = "Setup Vaultwarden admin user and organization";
    after = [
      "k3s-media.target"
      "vaultwarden-setup.service"
    ];
    requires = [
      "k3s-media.target"
      "vaultwarden-setup.service"
    ];
    # TIER 5: Extras
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vaultwarden-admin-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Vaultwarden Admin"

        # Wait for Vaultwarden namespace and pod to exist (handles race with vaultwarden-setup)
        echo "Waiting for namespace ${ns} to exist..."
        for i in $(seq 1 60); do
          if $KUBECTL get namespace ${ns} &>/dev/null; then
            echo "Namespace ${ns} exists"
            break
          fi
          if [ $i -eq 60 ]; then
            echo "ERROR: Namespace ${ns} not found after 5 minutes"
            exit 1
          fi
          sleep 5
        done

        wait_for_pod "${ns}" "app.kubernetes.io/name=vaultwarden" 300

        # Verify pod is actually ready (wait_for_pod uses || true)
        if ! $KUBECTL get pod -n ${ns} -l app.kubernetes.io/name=vaultwarden -o name 2>/dev/null | grep -q pod; then
          echo "ERROR: Vaultwarden pod not found after waiting"
          exit 1
        fi

        # ============================================
        # ADMIN PASSWORD & TOKEN
        # ============================================

        ADMIN_PASSWORD=$(get_secret_value "${ns}" "${credSecretName}" "ADMIN_PASSWORD")
        ADMIN_TOKEN_HASH=$(get_secret_value "${ns}" "${credSecretName}" "ADMIN_TOKEN_HASH")
        if [ -n "$ADMIN_PASSWORD" ]; then
          echo "Reusing existing admin password from K8s secret"
        fi

        # Check if ADMIN_TOKEN is already set on the StatefulSet
        EXISTING_TOKEN=$($KUBECTL get statefulset vaultwarden -n ${ns} \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_TOKEN")].value}' 2>/dev/null || true)
        if [ -n "$EXISTING_TOKEN" ] && [ -n "$ADMIN_PASSWORD" ]; then
          echo "ADMIN_TOKEN already set on StatefulSet, skipping token setup"
          ADMIN_TOKEN_HASH="$EXISTING_TOKEN"
        fi

        # Generate new admin password if needed
        if [ -z "$ADMIN_PASSWORD" ]; then
          ADMIN_PASSWORD=$($OPENSSL rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
          echo "Generated new admin password"
        fi

        # Hash with argon2id if needed
        if [ -z "$ADMIN_TOKEN_HASH" ]; then
          echo "Hashing admin password with argon2id..."
          SALT=$($OPENSSL rand -base64 32)
          ADMIN_TOKEN_HASH=$(echo -n "$ADMIN_PASSWORD" | ${pkgs.libargon2}/bin/argon2 "$SALT" -e -id -k 65540 -t 3 -p 4)
          echo "Admin token hashed"
        fi

        # Apply ADMIN_TOKEN to StatefulSet
        if [ -z "$EXISTING_TOKEN" ]; then
          echo "Setting ADMIN_TOKEN on Vaultwarden StatefulSet..."
          $KUBECTL set env statefulset/vaultwarden -n ${ns} \
            ADMIN_TOKEN="$ADMIN_TOKEN_HASH"

          echo "Waiting for Vaultwarden pod to restart..."
          sleep 10
          wait_for_pod "${ns}" "app.kubernetes.io/name=vaultwarden" 300
        fi

        # ============================================
        # USER REGISTRATION & ORG CREATION
        # ============================================

        # Read user password from agenix secret
        if [ ! -f "${config.age.secrets.vaultwarden-admin-password.path}" ]; then
          echo "ERROR: Vaultwarden admin password secret not found"
          exit 1
        fi
        USER_PASSWORD=$(cat ${config.age.secrets.vaultwarden-admin-password.path})

        # Port-forward to Vaultwarden
        echo "Starting port-forward to Vaultwarden..."
        # Kill any leftover port-forward from a previous failed run
        ${pkgs.procps}/bin/pkill -f 'kubectl port-forward.*8222' 2>/dev/null || true
        sleep 1

        $KUBECTL port-forward -n ${ns} svc/vaultwarden 8222:80 &
        PF_PID=$!
        cleanup() {
          kill $PF_PID 2>/dev/null || true
        }
        trap cleanup EXIT
        sleep 3

        # Verify port-forward is working
        for i in $(seq 1 10); do
          if $CURL -sf http://localhost:8222/alive > /dev/null 2>&1; then
            echo "Port-forward ready"
            break
          fi
          if [ $i -eq 10 ]; then
            echo "ERROR: Port-forward not ready after 10 attempts"
            exit 1
          fi
          sleep 2
        done

        # Run Python setup script
        echo "Running Vaultwarden admin setup script..."
        ${python}/bin/python3 ${vaultwardenAdminScript} \
          "http://localhost:8222" \
          "${adminEmail}" \
          "$USER_PASSWORD"

        PYTHON_EXIT=$?
        if [ $PYTHON_EXIT -ne 0 ]; then
          echo "ERROR: Python setup script failed with exit code $PYTHON_EXIT"
          exit 1
        fi

        # Disable signups after admin user is registered
        $KUBECTL set env statefulset/vaultwarden -n ${ns} \
          SIGNUPS_ALLOWED="false"
        sleep 5
        wait_for_pod "${ns}" "app.kubernetes.io/name=vaultwarden" 300

        # ============================================
        # SAVE CREDENTIALS
        # ============================================

        store_credentials "${ns}" "${credSecretName}" \
          "ADMIN_PASSWORD=$ADMIN_PASSWORD" "ADMIN_TOKEN_HASH=$ADMIN_TOKEN_HASH" \
          "USER_EMAIL=${adminEmail}" "USER_PASSWORD=$USER_PASSWORD"

        print_success "Vaultwarden Admin" \
          "URLs:" \
          "  Admin Panel: https://$(hostname vault)/admin" \
          "  Vault: https://$(hostname vault)" \
          "" \
          "Credentials stored in K8s secret ${credSecretName}"

        create_marker "${markerFile}"
      '';
    };
  };
}
