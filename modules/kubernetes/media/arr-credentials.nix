{
  k8s,
  config,
  lib,
  pkgs,
  ...
}:

let
  arr = import ./arr-lib.nix { inherit lib; };
  ns = arr.ns;
  markerFile = "/var/lib/arr-credentials-setup-done";

  authApps = [
    {
      app = "sonarr";
      host = "sonarr";
    }
    {
      app = "sonarr-es";
      host = "sonarr-es";
      pre = ''
        $KUBECTL exec -n ${ns} deploy/sonarr-es -- \
          sed -i 's/<AuthenticationMethod>None</<AuthenticationMethod>Forms</' /config/config.xml 2>/dev/null || true
      '';
    }
    {
      app = "radarr";
      host = "radarr";
    }
    {
      app = "radarr-es";
      host = "radarr-es";
    }
    {
      app = "prowlarr";
      host = "prowlarr";
    }
    {
      app = "lidarr";
      host = "lidarr";
    }
    {
      app = "bookshelf";
      host = "books";
    }
  ];

  authCall =
    entry:
    (entry.pre or "")
    + ''
      set_auth ${entry.app} "https://${k8s.hostname entry.host}"
    '';
in
{
  systemd.services.arr-credentials-setup = {
    description = "Configure credentials for arr-stack services";
    after = [
      "k3s-apps.target"
      "arr-stack-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [ "arr-stack-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "arr-credentials-setup" ''
        ${k8s.libShSource}
        set -e
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        setup_preamble "${markerFile}" "Credentials"
        wait_for_k3s

        ${arr.helpers}

        echo "Configuring credentials for services..."

        set_auth() {
          local app="$1" url="$2" label key pass current updated
          label=$(arr_label "$app")
          arr_ready "$app" || { echo "  $label: not running, skipped"; return 0; }

          key=$(arr_stable_key "$app")
          if [ -z "$key" ]; then
            echo "  $label: no stable API key yet, skipped"
            return 0
          fi

          pass=$(get_secret_value ${ns} "$app-credentials" PASSWORD)
          [ -z "$pass" ] && pass=$(generate_password 16)

          current=$(arr_get "$app" config/host)
          if [ -n "$current" ]; then
            updated=$(echo "$current" | $JQ --arg user admin --arg pass "$pass" \
              '.username = $user | .password = $pass | .passwordConfirmation = $pass | .authenticationMethod = "forms"')
            arr_put "$app" config/host "$updated" >/dev/null 2>&1
          fi

          store_credentials ${ns} "$app-credentials" \
            "USER=admin" "PASSWORD=$pass" "API_KEY=$key" "URL=$url"
          echo "  $label: OK"
        }

        ${lib.concatMapStringsSep "\n        " authCall authApps}
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
