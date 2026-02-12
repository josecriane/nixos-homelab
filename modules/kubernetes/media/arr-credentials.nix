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
  markerFile = "/var/lib/arr-credentials-setup-done";
in
{
  systemd.services.arr-credentials-setup = {
    description = "Setup credentials for arr-stack and media services";
    # After Tier 4 Media
    after = [
      "k3s-media.target"
      "arr-stack-setup.service"
      "arr-secrets-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [
      "arr-stack-setup.service"
      "arr-secrets-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "arr-credentials-setup" ''
        ${k8s.libShSource}
        set -e
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        MARKER_FILE="${markerFile}"
        if [ -f "$MARKER_FILE" ]; then
          echo "Credentials already configured"
          exit 0
        fi

        wait_for_k3s

        echo "Configuring credentials for services..."

        # Helper function to wait for pod by app label
        wait_for_app_pod() {
          local app=$1
          for i in $(seq 1 30); do
            if $KUBECTL get pods -n ${ns} -l app=$app -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q "true"; then
              return 0
            fi
            sleep 5
          done
          return 1
        }

        # ============================================
        # SONARR
        # ============================================
        if wait_for_app_pod "sonarr"; then
          echo "Configuring Sonarr..."
          SONARR_API=$($KUBECTL get secret sonarr-api-key -n ${ns} -o jsonpath='{.data.api-key}' | base64 -d 2>/dev/null || echo "")

          if [ -n "$SONARR_API" ]; then
            SONARR_PASS=$(get_secret_value "${ns}" "sonarr-credentials" "PASSWORD")
            [ -z "$SONARR_PASS" ] && SONARR_PASS=$(generate_password 16)

            # Get current config and update with credentials
            CURRENT_CONFIG=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
              curl -s "http://localhost:8989/api/v3/config/host" -H "X-Api-Key: $SONARR_API" 2>/dev/null)

            if [ -n "$CURRENT_CONFIG" ]; then
              # Update config with username and password
              UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | $JQ \
                --arg user "admin" \
                --arg pass "$SONARR_PASS" \
                '.username = $user | .password = $pass | .passwordConfirmation = $pass | .authenticationMethod = "forms"')

              $KUBECTL exec -n ${ns} deploy/sonarr -- \
                curl -s -X PUT "http://localhost:8989/api/v3/config/host" \
                -H "X-Api-Key: $SONARR_API" \
                -H "Content-Type: application/json" \
                -d "$UPDATED_CONFIG" >/dev/null 2>&1
            fi

            store_credentials "${ns}" "sonarr-credentials" "USER=admin" "PASSWORD=$SONARR_PASS" "API_KEY=$SONARR_API" "URL=https://${k8s.hostname "sonarr"}"
            echo "  Sonarr: OK"
          fi
        fi

        # ============================================
        # SONARR ES (Spanish)
        # ============================================
        if wait_for_app_pod "sonarr-es"; then
          echo "Configuring Sonarr ES..."

          # Ensure AuthenticationMethod is Forms in config.xml before API call
          $KUBECTL exec -n ${ns} deploy/sonarr-es -- \
            sed -i 's/<AuthenticationMethod>None</<AuthenticationMethod>Forms</' /config/config.xml 2>/dev/null || true

          SONARR_ES_API=$($KUBECTL get secret sonarr-es-api-key -n ${ns} -o jsonpath='{.data.api-key}' | base64 -d 2>/dev/null || echo "")

          if [ -n "$SONARR_ES_API" ]; then
            SONARR_ES_PASS=$(get_secret_value "${ns}" "sonarr-es-credentials" "PASSWORD")
            [ -z "$SONARR_ES_PASS" ] && SONARR_ES_PASS=$(generate_password 16)

            CURRENT_CONFIG=$($KUBECTL exec -n ${ns} deploy/sonarr-es -- \
              curl -s "http://localhost:8989/api/v3/config/host" -H "X-Api-Key: $SONARR_ES_API" 2>/dev/null)

            if [ -n "$CURRENT_CONFIG" ]; then
              UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | $JQ \
                --arg user "admin" \
                --arg pass "$SONARR_ES_PASS" \
                '.username = $user | .password = $pass | .passwordConfirmation = $pass | .authenticationMethod = "forms"')

              $KUBECTL exec -n ${ns} deploy/sonarr-es -- \
                curl -s -X PUT "http://localhost:8989/api/v3/config/host" \
                -H "X-Api-Key: $SONARR_ES_API" \
                -H "Content-Type: application/json" \
                -d "$UPDATED_CONFIG" >/dev/null 2>&1
            fi

            store_credentials "${ns}" "sonarr-es-credentials" "USER=admin" "PASSWORD=$SONARR_ES_PASS" "API_KEY=$SONARR_ES_API" "URL=https://${k8s.hostname "sonarr-es"}"
            echo "  Sonarr ES: OK"
          fi
        fi

        # ============================================
        # RADARR
        # ============================================
        if wait_for_app_pod "radarr"; then
          echo "Configuring Radarr..."
          RADARR_API=$($KUBECTL get secret radarr-api-key -n ${ns} -o jsonpath='{.data.api-key}' | base64 -d 2>/dev/null || echo "")

          if [ -n "$RADARR_API" ]; then
            RADARR_PASS=$(get_secret_value "${ns}" "radarr-credentials" "PASSWORD")
            [ -z "$RADARR_PASS" ] && RADARR_PASS=$(generate_password 16)

            CURRENT_CONFIG=$($KUBECTL exec -n ${ns} deploy/radarr -- \
              curl -s "http://localhost:7878/api/v3/config/host" -H "X-Api-Key: $RADARR_API" 2>/dev/null)

            if [ -n "$CURRENT_CONFIG" ]; then
              UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | $JQ \
                --arg user "admin" \
                --arg pass "$RADARR_PASS" \
                '.username = $user | .password = $pass | .passwordConfirmation = $pass | .authenticationMethod = "forms"')

              $KUBECTL exec -n ${ns} deploy/radarr -- \
                curl -s -X PUT "http://localhost:7878/api/v3/config/host" \
                -H "X-Api-Key: $RADARR_API" \
                -H "Content-Type: application/json" \
                -d "$UPDATED_CONFIG" >/dev/null 2>&1
            fi

            store_credentials "${ns}" "radarr-credentials" "USER=admin" "PASSWORD=$RADARR_PASS" "API_KEY=$RADARR_API" "URL=https://${k8s.hostname "radarr"}"
            echo "  Radarr: OK"
          fi
        fi

        # ============================================
        # RADARR ES (Spanish)
        # ============================================
        if wait_for_app_pod "radarr-es"; then
          echo "Configuring Radarr ES..."

          # Ensure AuthenticationMethod is Forms in config.xml before API call
          $KUBECTL exec -n ${ns} deploy/radarr-es -- \
            sed -i 's/<AuthenticationMethod>None</<AuthenticationMethod>Forms</' /config/config.xml 2>/dev/null || true

          RADARR_ES_API=$($KUBECTL get secret radarr-es-api-key -n ${ns} -o jsonpath='{.data.api-key}' | base64 -d 2>/dev/null || echo "")

          if [ -n "$RADARR_ES_API" ]; then
            RADARR_ES_PASS=$(get_secret_value "${ns}" "radarr-es-credentials" "PASSWORD")
            [ -z "$RADARR_ES_PASS" ] && RADARR_ES_PASS=$(generate_password 16)

            CURRENT_CONFIG=$($KUBECTL exec -n ${ns} deploy/radarr-es -- \
              curl -s "http://localhost:7878/api/v3/config/host" -H "X-Api-Key: $RADARR_ES_API" 2>/dev/null)

            if [ -n "$CURRENT_CONFIG" ]; then
              UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | $JQ \
                --arg user "admin" \
                --arg pass "$RADARR_ES_PASS" \
                '.username = $user | .password = $pass | .passwordConfirmation = $pass | .authenticationMethod = "forms"')

              $KUBECTL exec -n ${ns} deploy/radarr-es -- \
                curl -s -X PUT "http://localhost:7878/api/v3/config/host" \
                -H "X-Api-Key: $RADARR_ES_API" \
                -H "Content-Type: application/json" \
                -d "$UPDATED_CONFIG" >/dev/null 2>&1
            fi

            store_credentials "${ns}" "radarr-es-credentials" "USER=admin" "PASSWORD=$RADARR_ES_PASS" "API_KEY=$RADARR_ES_API" "URL=https://${k8s.hostname "radarr-es"}"
            echo "  Radarr ES: OK"
          fi
        fi

        # ============================================
        # PROWLARR
        # ============================================
        if wait_for_app_pod "prowlarr"; then
          echo "Configuring Prowlarr..."
          PROWLARR_API=$($KUBECTL get secret prowlarr-api-key -n ${ns} -o jsonpath='{.data.api-key}' | base64 -d 2>/dev/null || echo "")

          if [ -n "$PROWLARR_API" ]; then
            PROWLARR_PASS=$(get_secret_value "${ns}" "prowlarr-credentials" "PASSWORD")
            [ -z "$PROWLARR_PASS" ] && PROWLARR_PASS=$(generate_password 16)

            CURRENT_CONFIG=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              curl -s "http://localhost:9696/api/v1/config/host" -H "X-Api-Key: $PROWLARR_API" 2>/dev/null)

            if [ -n "$CURRENT_CONFIG" ]; then
              UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | $JQ \
                --arg user "admin" \
                --arg pass "$PROWLARR_PASS" \
                '.username = $user | .password = $pass | .passwordConfirmation = $pass | .authenticationMethod = "forms"')

              $KUBECTL exec -n ${ns} deploy/prowlarr -- \
                curl -s -X PUT "http://localhost:9696/api/v1/config/host" \
                -H "X-Api-Key: $PROWLARR_API" \
                -H "Content-Type: application/json" \
                -d "$UPDATED_CONFIG" >/dev/null 2>&1
            fi

            store_credentials "${ns}" "prowlarr-credentials" "USER=admin" "PASSWORD=$PROWLARR_PASS" "API_KEY=$PROWLARR_API" "URL=https://${k8s.hostname "prowlarr"}"
            echo "  Prowlarr: OK"
          fi
        fi

        # ============================================
        # LIDARR
        # ============================================
        if wait_for_app_pod "lidarr"; then
          echo "Configuring Lidarr..."
          LIDARR_API=$($KUBECTL get secret lidarr-api-key -n ${ns} -o jsonpath='{.data.api-key}' | base64 -d 2>/dev/null || echo "")

          if [ -n "$LIDARR_API" ]; then
            LIDARR_PASS=$(get_secret_value "${ns}" "lidarr-credentials" "PASSWORD")
            [ -z "$LIDARR_PASS" ] && LIDARR_PASS=$(generate_password 16)

            CURRENT_CONFIG=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
              curl -s "http://localhost:8686/api/v1/config/host" -H "X-Api-Key: $LIDARR_API" 2>/dev/null)

            if [ -n "$CURRENT_CONFIG" ]; then
              UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | $JQ \
                --arg user "admin" \
                --arg pass "$LIDARR_PASS" \
                '.username = $user | .password = $pass | .passwordConfirmation = $pass | .authenticationMethod = "forms"')

              $KUBECTL exec -n ${ns} deploy/lidarr -- \
                curl -s -X PUT "http://localhost:8686/api/v1/config/host" \
                -H "X-Api-Key: $LIDARR_API" \
                -H "Content-Type: application/json" \
                -d "$UPDATED_CONFIG" >/dev/null 2>&1
            fi

            store_credentials "${ns}" "lidarr-credentials" "USER=admin" "PASSWORD=$LIDARR_PASS" "API_KEY=$LIDARR_API" "URL=https://${k8s.hostname "lidarr"}"
            echo "  Lidarr: OK"
          fi
        fi

        # ============================================
        # BAZARR
        # ============================================
        if wait_for_app_pod "bazarr"; then
          echo "Configuring Bazarr..."
          sleep 10  # Bazarr needs time to initialize

          # Read auto-generated API key from Bazarr config
          BAZARR_API=$($KUBECTL exec -n ${ns} deploy/bazarr -- \
            sh -c "grep 'apikey:' /config/config/config.yaml 2>/dev/null | head -1 | sed 's/.*apikey: *//' | tr -d ' '" 2>/dev/null || echo "")

          if [ -n "$BAZARR_API" ]; then
            store_credentials "${ns}" "bazarr-credentials" "USER=admin" "PASSWORD=" "API_KEY=$BAZARR_API" "URL=https://${k8s.hostname "bazarr"}"
            echo "  Bazarr: OK"
          else
            echo "  Bazarr: Could not read API key from config"
          fi
        fi

        # ============================================
        # QBITTORRENT
        # ============================================
        if wait_for_app_pod "qbittorrent"; then
          echo "Configuring qBittorrent..."
          sleep 10  # Wait for qBittorrent to initialize

          QBIT_PASS=$(get_secret_value "${ns}" "qbittorrent-credentials" "PASSWORD")
          QBIT_PASS_IS_NEW=false
          [ -z "$QBIT_PASS" ] && QBIT_PASS=$(generate_password 16) && QBIT_PASS_IS_NEW=true
          QBIT_COOKIE=""

          # Try to login with existing stored password first (already set from previous run)
          if [ "$QBIT_PASS_IS_NEW" = "false" ]; then
            LOGIN_RESULT=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
              curl -s "http://localhost:8080/api/v2/auth/login" \
              -d "username=admin&password=$QBIT_PASS" 2>/dev/null)
            if [ "$LOGIN_RESULT" = "Ok." ]; then
              echo "  qBittorrent: Existing password works"
              QBIT_COOKIE="ALREADY_SET"
            fi
          fi

          # If existing password didn't work, try default and temp passwords
          if [ -z "$QBIT_COOKIE" ]; then
            LOGIN_RESULT=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
              curl -s "http://localhost:8080/api/v2/auth/login" \
              -d "username=admin&password=adminadmin" 2>/dev/null)

            if [ "$LOGIN_RESULT" = "Ok." ]; then
              QBIT_COOKIE=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                curl -s -c - "http://localhost:8080/api/v2/auth/login" \
                -d "username=admin&password=adminadmin" 2>/dev/null | grep -oP 'SID\s+\K\S+' || echo "")
            else
              # Try to get temporary password from logs
              TEMP_PASS=$($KUBECTL logs -n ${ns} deploy/qbittorrent 2>/dev/null | \
                grep -oP "temporary password is provided.*: \K\S+" | tail -1 || echo "")

              if [ -n "$TEMP_PASS" ]; then
                echo "  qBittorrent: Using temporary password from log"
                QBIT_COOKIE=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                  curl -s -c - "http://localhost:8080/api/v2/auth/login" \
                  -d "username=admin&password=$TEMP_PASS" 2>/dev/null | grep -oP 'SID\s+\K\S+' || echo "")
              fi
            fi

            if [ -n "$QBIT_COOKIE" ] && [ "$QBIT_COOKIE" != "ALREADY_SET" ]; then
              # Change password and disable IP banning to avoid lockouts during setup
              $KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                curl -s "http://localhost:8080/api/v2/app/setPreferences" \
                -b "SID=$QBIT_COOKIE" \
                --data-urlencode 'json={"web_ui_password":"'"$QBIT_PASS"'","web_ui_max_auth_fail_count":999999}' 2>/dev/null || true
              echo "  qBittorrent: Password updated"
            elif [ -z "$QBIT_COOKIE" ]; then
              # All login methods failed -- reset qBittorrent config to force default password
              echo "  qBittorrent: Resetting config to force default password..."
              $KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                sh -c "rm -f /config/qBittorrent/qBittorrent.conf" 2>/dev/null || true
              $KUBECTL rollout restart deployment/qbittorrent -n ${ns}
              $KUBECTL rollout status deployment/qbittorrent -n ${ns} --timeout=120s 2>/dev/null || true
              sleep 15

              # Now login with default password and set our password
              QBIT_PASS=$(generate_password 16)
              QBIT_COOKIE=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                curl -s -c - "http://localhost:8080/api/v2/auth/login" \
                -d "username=admin&password=adminadmin" 2>/dev/null | grep -oP 'SID\s+\K\S+' || echo "")
              if [ -n "$QBIT_COOKIE" ]; then
                $KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                  curl -s "http://localhost:8080/api/v2/app/setPreferences" \
                  -b "SID=$QBIT_COOKIE" \
                  --data-urlencode 'json={"web_ui_password":"'"$QBIT_PASS"'","web_ui_max_auth_fail_count":999999}' 2>/dev/null || true
                echo "  qBittorrent: Password reset and updated"
              else
                echo "  qBittorrent: ERROR - Could not reset"
              fi
            fi
          fi

          store_credentials "${ns}" "qbittorrent-credentials" "USER=admin" "PASSWORD=$QBIT_PASS" "URL=https://${k8s.hostname "qbit"}"
          echo "  qBittorrent: OK"
        fi

        # ============================================
        # BOOKSHELF
        # ============================================
        if wait_for_app_pod "bookshelf"; then
          echo "Configuring Bookshelf..."
          BOOKSHELF_API=$($KUBECTL get secret bookshelf-api-key -n ${ns} -o jsonpath='{.data.api-key}' | base64 -d 2>/dev/null || echo "")

          if [ -n "$BOOKSHELF_API" ]; then
            BOOKSHELF_PASS=$(get_secret_value "${ns}" "bookshelf-credentials" "PASSWORD")
            [ -z "$BOOKSHELF_PASS" ] && BOOKSHELF_PASS=$(generate_password 16)

            CURRENT_CONFIG=$($KUBECTL exec -n ${ns} deploy/bookshelf -- \
              curl -s "http://localhost:8787/api/v1/config/host" -H "X-Api-Key: $BOOKSHELF_API" 2>/dev/null)

            if [ -n "$CURRENT_CONFIG" ]; then
              UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | $JQ \
                --arg user "admin" \
                --arg pass "$BOOKSHELF_PASS" \
                '.username = $user | .password = $pass | .passwordConfirmation = $pass | .authenticationMethod = "forms"')

              $KUBECTL exec -n ${ns} deploy/bookshelf -- \
                curl -s -X PUT "http://localhost:8787/api/v1/config/host" \
                -H "X-Api-Key: $BOOKSHELF_API" \
                -H "Content-Type: application/json" \
                -d "$UPDATED_CONFIG" >/dev/null 2>&1
            fi

            store_credentials "${ns}" "bookshelf-credentials" "USER=admin" "PASSWORD=$BOOKSHELF_PASS" "API_KEY=$BOOKSHELF_API" "URL=https://${k8s.hostname "books"}"
            echo "  Bookshelf: OK"
          fi
        fi

        # ============================================
        # SYNCTHING
        # ============================================
        if $KUBECTL get deploy -n syncthing syncthing &>/dev/null; then
          echo "Configuring Syncthing..."

          # Credentials are configured in syncthing-setup service via REST API
          SYNC_API=$(get_secret_value syncthing syncthing-credentials API_KEY)
          if [ -n "$SYNC_API" ]; then
            echo "  Syncthing: Credentials already configured"
          else
            echo "  Syncthing: Credentials will be set by syncthing-setup service"
          fi
        fi

        echo ""
        echo "=== Credentials configured ==="
        echo "Credentials saved to K8s secrets"

        create_marker "${markerFile}"
      '';
    };
  };
}
