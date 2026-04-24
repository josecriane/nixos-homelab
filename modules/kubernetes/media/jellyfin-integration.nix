{
  config,
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/jellyfin-integration-setup-done";
  curl = "curl";
  curlBin = "${pkgs.curl}/bin/curl";
  migratorPodYaml = ./_migrator-pod.yaml;
in
{
  systemd.services.jellyfin-integration-setup = {
    description = "Configure Jellyfin API key, Jellyseerr initialization, and Jellyfin notifications";
    after = [
      "k3s-apps.target"
      "arr-credentials-setup.service"
      "arr-download-clients-setup.service"
      "recyclarr-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [
      "arr-credentials-setup.service"
      "arr-download-clients-setup.service"
      "recyclarr-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "jellyfin-integration-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        MARKER_FILE="${markerFile}"
        if [ -f "$MARKER_FILE" ]; then
          echo "Jellyfin integration already configured"
          exit 0
        fi

        wait_for_k3s

        echo "Configuring Jellyfin integration..."

        wait_for_app_pod() {
          local app=$1
          if [ "$($KUBECTL get deploy -n ${ns} "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null)" = "0" ]; then
            return 1
          fi
          for i in $(seq 1 30); do
            if $KUBECTL get pods -n ${ns} -l app=$app -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q "true"; then
              return 0
            fi
            if $KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=$app -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q "true"; then
              return 0
            fi
            sleep 5
          done
          return 1
        }

        SONARR_API=$(get_secret_value ${ns} sonarr-credentials API_KEY)
        SONARR_ES_API=$(get_secret_value ${ns} sonarr-es-credentials API_KEY)
        RADARR_API=$(get_secret_value ${ns} radarr-credentials API_KEY)
        RADARR_ES_API=$(get_secret_value ${ns} radarr-es-credentials API_KEY)

        if [ -z "$SONARR_API" ] || [ -z "$RADARR_API" ]; then
          echo "ERROR: Required credentials not found"
          exit 1
        fi

        # ============================================
        # GET JELLYFIN API KEY
        # ============================================
        echo ""
        echo "=== Getting Jellyfin API key ==="

        JELLYFIN_API=""
        ADMIN_USER=$(get_secret_value ${ns} jellyfin-credentials ADMIN_USER)
        ADMIN_PASSWORD=$(get_secret_value ${ns} jellyfin-credentials ADMIN_PASSWORD)
        if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASSWORD" ] && wait_for_app_pod "jellyfin"; then

          JF_AUTH=$($KUBECTL exec -n ${ns} deploy/jellyfin -- \
            ${curl} -s -X POST "http://localhost:8096/Users/AuthenticateByName" \
            -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: MediaBrowser Client=\"ArrStack\", Device=\"NixOS\", DeviceId=\"setup\", Version=\"1.0\"" \
            -d "{\"Username\":\"$ADMIN_USER\",\"Pw\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "{}")
          JF_TOKEN=$(echo "$JF_AUTH" | $JQ -r '.AccessToken // empty' 2>/dev/null || echo "")

          if [ -n "$JF_TOKEN" ]; then
            JELLYFIN_API=$($KUBECTL exec -n ${ns} deploy/jellyfin -- \
              ${curl} -s "http://localhost:8096/Auth/Keys?api_key=$JF_TOKEN" 2>/dev/null | \
              $JQ -r '.Items[] | select(.AppName == "ArrStack") | .AccessToken' 2>/dev/null || echo "")

            if [ -z "$JELLYFIN_API" ]; then
              $KUBECTL exec -n ${ns} deploy/jellyfin -- \
                ${curl} -s -X POST "http://localhost:8096/Auth/Keys?app=ArrStack&api_key=$JF_TOKEN" 2>/dev/null || true
              sleep 2
              JELLYFIN_API=$($KUBECTL exec -n ${ns} deploy/jellyfin -- \
                ${curl} -s "http://localhost:8096/Auth/Keys?api_key=$JF_TOKEN" 2>/dev/null | \
                $JQ -r '.Items[] | select(.AppName == "ArrStack") | .AccessToken' 2>/dev/null || echo "")
            fi

            if [ -n "$JELLYFIN_API" ]; then
              echo "  Jellyfin API key: OK (ArrStack)"
              JELLYFIN_SERVER_ID=$($KUBECTL exec -n ${ns} deploy/jellyfin -- \
                ${curl} -s "http://localhost:8096/System/Info/Public" 2>/dev/null | \
                $JQ -r '.Id // empty' 2>/dev/null || echo "")
              JELLYFIN_LIBRARIES=$($KUBECTL exec -n ${ns} deploy/jellyfin -- \
                ${curl} -s "http://localhost:8096/Library/VirtualFolders?api_key=$JF_TOKEN" 2>/dev/null | \
                $JQ '[.[] | {id: .ItemId, name: .Name, enabled: true}]' 2>/dev/null || echo "[]")
            else
              echo "  Jellyfin API key: Error creating"
            fi
          else
            echo "  Jellyfin: Authentication error"
          fi
        else
          echo "  Jellyfin: No credentials (jellyfin-credentials secret missing)"
        fi

        # ============================================
        # CONFIGURE JELLYSEERR
        # ============================================
        echo ""
        echo "=== Configuring Jellyseerr ==="

        if wait_for_app_pod "jellyseerr" && [ -n "$JELLYFIN_API" ] && [ -n "$JELLYFIN_SERVER_ID" ]; then
          JSEERR_SETTINGS_CONTENT=$($KUBECTL exec -n ${ns} deploy/jellyseerr -- \
            cat /app/config/settings.json 2>/dev/null || echo "")
          IS_INITIALIZED="false"
          JS_MEDIA_TYPE="4"
          if [ -n "$JSEERR_SETTINGS_CONTENT" ]; then
            IS_INITIALIZED=$(echo "$JSEERR_SETTINGS_CONTENT" | $JQ -r '.public.initialized // false' 2>/dev/null || echo "false")
            JS_MEDIA_TYPE=$(echo "$JSEERR_SETTINGS_CONTENT" | $JQ -r '.main.mediaServerType // 4' 2>/dev/null || echo "4")
          fi

          if [ "$IS_INITIALIZED" = "true" ] && [ "$JS_MEDIA_TYPE" = "2" ]; then
            echo "  Jellyseerr: already initialized"

            JELLYSEERR_API_KEY=$(echo "$JSEERR_SETTINGS_CONTENT" | $JQ -r '.main.apiKey // empty' 2>/dev/null || echo "")
            if [ -n "$JELLYSEERR_API_KEY" ]; then
              store_credentials "${ns}" "jellyseerr-credentials" \
                "API_KEY=$JELLYSEERR_API_KEY" "URL=https://$(hostname requests)"
            fi
          else
            echo "  Initializing Jellyseerr..."

            # Get quality profiles by name (TRaSH Guides profiles from Recyclarr)
            RADARR_PROFILES=$($KUBECTL exec -n ${ns} deploy/radarr -- \
              ${curl} -s "http://localhost:7878/api/v3/qualityprofile" \
              -H "X-Api-Key: $RADARR_API" 2>/dev/null)
            RADARR_PROFILE_ID=$(echo "$RADARR_PROFILES" | $JQ '[.[] | select(.name == "HD Bluray + WEB")][0].id // .[0].id' 2>/dev/null || echo "1")
            RADARR_PROFILE_NAME=$(echo "$RADARR_PROFILES" | $JQ -r '[.[] | select(.name == "HD Bluray + WEB")][0].name // .[0].name' 2>/dev/null || echo "Any")

            SONARR_PROFILES=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
              ${curl} -s "http://localhost:8989/api/v3/qualityprofile" \
              -H "X-Api-Key: $SONARR_API" 2>/dev/null)
            SONARR_PROFILE_ID=$(echo "$SONARR_PROFILES" | $JQ '[.[] | select(.name == "WEB-1080p")][0].id // .[0].id' 2>/dev/null || echo "1")
            SONARR_PROFILE_NAME=$(echo "$SONARR_PROFILES" | $JQ -r '[.[] | select(.name == "WEB-1080p")][0].name // .[0].name' 2>/dev/null || echo "Any")
            SONARR_ANIME_PROFILE_ID=$(echo "$SONARR_PROFILES" | $JQ '[.[] | select(.name == "Remux-1080p - Anime")][0].id // .[0].id' 2>/dev/null || echo "1")
            SONARR_ANIME_PROFILE_NAME=$(echo "$SONARR_PROFILES" | $JQ -r '[.[] | select(.name == "Remux-1080p - Anime")][0].name // .[0].name' 2>/dev/null || echo "Any")

            # Step 1: Scale down and write Radarr/Sonarr config to settings.json
            echo "    Writing Radarr/Sonarr config to settings.json..."
            $KUBECTL scale deploy -n ${ns} jellyseerr --replicas=0 2>/dev/null
            for i in $(seq 1 30); do
              REMAINING=$($KUBECTL get pods -n ${ns} -l app=jellyseerr --no-headers 2>/dev/null | wc -l)
              [ "$REMAINING" -eq 0 ] && break
              sleep 2
            done
            sleep 2

            if [ -n "$JSEERR_SETTINGS" ] && [ -f "$JSEERR_SETTINGS" ]; then
              $JQ \
                --arg radarr_api "$RADARR_API" \
                --argjson radarr_pid "''${RADARR_PROFILE_ID:-1}" \
                --arg radarr_pname "''${RADARR_PROFILE_NAME:-Any}" \
                --arg radarr_es_api "$RADARR_ES_API" \
                --arg sonarr_api "$SONARR_API" \
                --argjson sonarr_pid "''${SONARR_PROFILE_ID:-1}" \
                --arg sonarr_pname "''${SONARR_PROFILE_NAME:-Any}" \
                --argjson sonarr_anime_pid "''${SONARR_ANIME_PROFILE_ID:-1}" \
                --arg sonarr_anime_pname "''${SONARR_ANIME_PROFILE_NAME:-Any}" \
                --arg sonarr_es_api "$SONARR_ES_API" \
                '
                .jellyfin.ip = "" |
                .jellyfin.apiKey = "" |
                .jellyfin.serverId = "" |
                .jellyfin.name = "" |
                .main.defaultPermissions = 2 |
                .metadataSettings = {"tv": "tvdb", "anime": "tvdb"} |
                .public.initialized = true |
                .radarr = [{
                  "id": 0, "name": "Radarr", "hostname": "radarr.media.svc.cluster.local", "port": 7878,
                  "apiKey": $radarr_api, "useSsl": false, "baseUrl": "",
                  "activeProfileId": $radarr_pid, "activeProfileName": $radarr_pname,
                  "activeDirectory": "/data/media/movies", "is4k": false,
                  "minimumAvailability": "released", "isDefault": true,
                  "externalUrl": "https://${k8s.hostname "radarr"}",
                  "syncEnabled": false, "preventSearch": false
                }, {
                  "id": 1, "name": "Radarr Spanish", "hostname": "radarr-es.media.svc.cluster.local", "port": 7878,
                  "apiKey": $radarr_es_api, "useSsl": false, "baseUrl": "",
                  "activeProfileId": $radarr_pid, "activeProfileName": $radarr_pname,
                  "activeDirectory": "/data/media/movies-es", "is4k": false,
                  "minimumAvailability": "released", "isDefault": false,
                  "externalUrl": "https://${k8s.hostname "radarr-es"}",
                  "syncEnabled": false, "preventSearch": false
                }] |
                .sonarr = [{
                  "id": 0, "name": "Sonarr", "hostname": "sonarr.media.svc.cluster.local", "port": 8989,
                  "apiKey": $sonarr_api, "useSsl": false, "baseUrl": "",
                  "activeProfileId": $sonarr_pid, "activeProfileName": $sonarr_pname,
                  "activeDirectory": "/data/media/tv",
                  "activeAnimeProfileId": $sonarr_anime_pid, "activeAnimeProfileName": $sonarr_anime_pname,
                  "activeAnimeDirectory": "/data/media/tv",
                  "activeLanguageProfileId": 1, "animeLanguageProfileId": 1,
                  "animeLookupSource": "tvdb",
                  "is4k": false, "isDefault": true,
                  "externalUrl": "https://${k8s.hostname "sonarr"}",
                  "syncEnabled": false, "preventSearch": false, "enableSeasonFolders": true
                }, {
                  "id": 1, "name": "Sonarr Spanish", "hostname": "sonarr-es.media.svc.cluster.local", "port": 8989,
                  "apiKey": $sonarr_es_api, "useSsl": false, "baseUrl": "",
                  "activeProfileId": $sonarr_pid, "activeProfileName": $sonarr_pname,
                  "activeDirectory": "/data/media/tv-es",
                  "activeAnimeProfileId": $sonarr_anime_pid, "activeAnimeProfileName": $sonarr_anime_pname,
                  "activeAnimeDirectory": "/data/media/tv-es",
                  "activeLanguageProfileId": 1, "animeLanguageProfileId": 1,
                  "animeLookupSource": "tvdb",
                  "is4k": false, "isDefault": false,
                  "externalUrl": "https://${k8s.hostname "sonarr-es"}",
                  "syncEnabled": false, "preventSearch": false, "enableSeasonFolders": true
                }]
                ' "$JSEERR_SETTINGS" > "''${JSEERR_SETTINGS}.tmp" && mv "''${JSEERR_SETTINGS}.tmp" "$JSEERR_SETTINGS"
              echo "    Radarr/Sonarr config written"
            fi

            # Step 2: Scale up and wait
            $KUBECTL scale deploy -n ${ns} jellyseerr --replicas=1 2>/dev/null
            $KUBECTL rollout status deployment/jellyseerr -n ${ns} --timeout=120s 2>/dev/null || true
            sleep 5

            # Step 3: Auth via API to create admin user + configure Jellyfin
            pkill -f 'port-forward.*jellyseerr' 2>/dev/null || true
            sleep 2
            $KUBECTL port-forward -n ${ns} svc/jellyseerr 15055:5055 &
            JS_PF_PID=$!
            sleep 3

            JS_URL="http://localhost:15055"

            JS_READY="false"
            for i in $(seq 1 30); do
              if ${curlBin} -s "$JS_URL/api/v1/status" 2>/dev/null | $JQ -e '.version' >/dev/null 2>&1; then
                JS_READY="true"
                break
              fi
              sleep 3
            done

            if [ "$JS_READY" = "true" ]; then
              echo "    Creating admin via Jellyfin auth..."
              AUTH_RESULT=$(${curlBin} -s -X POST "$JS_URL/api/v1/auth/jellyfin" \
                -H "Content-Type: application/json" \
                -d "{
                  \"username\": \"$ADMIN_USER\",
                  \"password\": \"$ADMIN_PASSWORD\",
                  \"hostname\": \"${k8s.hostname "jellyfin"}\",
                  \"port\": 443,
                  \"useSsl\": true,
                  \"urlBase\": \"\",
                  \"serverType\": 2
                }" 2>/dev/null || echo "{}")

              AUTH_ID=$(echo "$AUTH_RESULT" | $JQ -r '.id // empty' 2>/dev/null || echo "")

              if [ -n "$AUTH_ID" ]; then
                echo "    Admin created (id: $AUTH_ID)"

                # Write Jellyfin libraries to settings (scale down to avoid conflicts)
                kill $JS_PF_PID 2>/dev/null || true
                sleep 2
                $KUBECTL scale deploy -n ${ns} jellyseerr --replicas=0 2>/dev/null
                for i in $(seq 1 30); do
                  REMAINING=$($KUBECTL get pods -n ${ns} -l app=jellyseerr --no-headers 2>/dev/null | wc -l)
                  [ "$REMAINING" -eq 0 ] && break
                  sleep 2
                done

                # Mount jellyseerr-config PVC in migrator pod (no hostPath dependency)
                MIGRATOR_POD="jellyseerr-migrator-$$"
                ${pkgs.gnused}/bin/sed \
                  -e "s|__POD_NAME__|$MIGRATOR_POD|g" \
                  -e "s|__NAMESPACE__|${ns}|g" \
                  -e "s|__PVC_NAME__|jellyseerr-config|g" \
                  ${migratorPodYaml} | $KUBECTL apply -f - >/dev/null

                $KUBECTL wait --for=condition=ready "pod/$MIGRATOR_POD" -n ${ns} --timeout=120s
                JELLYSEERR_API_KEY=""
                TMP_SETTINGS=$(mktemp)
                if $KUBECTL cp "${ns}/$MIGRATOR_POD:/config/settings.json" "$TMP_SETTINGS" 2>/dev/null && [ -s "$TMP_SETTINGS" ]; then
                  JELLYSEERR_API_KEY=$($JQ -r '.main.apiKey // empty' "$TMP_SETTINGS" 2>/dev/null || echo "")

                  if [ -n "$JELLYFIN_LIBRARIES" ] && [ "$JELLYFIN_LIBRARIES" != "[]" ]; then
                    $JQ --argjson libs "$JELLYFIN_LIBRARIES" \
                      '.jellyfin.libraries = ($libs | map(select(.name != "Music")))' \
                      "$TMP_SETTINGS" > "''${TMP_SETTINGS}.tmp" && mv "''${TMP_SETTINGS}.tmp" "$TMP_SETTINGS"
                    $KUBECTL cp "$TMP_SETTINGS" "${ns}/$MIGRATOR_POD:/config/settings.json"
                    echo "    Jellyfin libraries configured"
                  fi
                fi
                rm -f "$TMP_SETTINGS"
                $KUBECTL delete "pod/$MIGRATOR_POD" -n ${ns} --wait --timeout=60s >/dev/null 2>&1 || true

                $KUBECTL scale deploy -n ${ns} jellyseerr --replicas=1 2>/dev/null
                $KUBECTL rollout status deployment/jellyseerr -n ${ns} --timeout=120s 2>/dev/null || true

                store_credentials "${ns}" "jellyseerr-credentials" \
                  "API_KEY=$JELLYSEERR_API_KEY" "URL=https://$(hostname requests)"
                echo "  Jellyseerr: initialized with Jellyfin + Radarr/Sonarr"
              else
                echo "  Jellyseerr: Auth failed - $(echo "$AUTH_RESULT" | $JQ -r '.message // "unknown error"' 2>/dev/null)"
              fi
            else
              echo "  Jellyseerr: API not available after 90s"
            fi

            kill $JS_PF_PID 2>/dev/null || true
          fi
        else
          echo "  Jellyseerr: Needs Jellyfin API key and server ID"
        fi

        # ============================================
        # CONFIGURE JELLYFIN NOTIFICATIONS
        # ============================================
        echo ""
        echo "=== Configuring Jellyfin notifications ==="

        # Verify API key is valid before configuring notifications
        if [ -n "$JELLYFIN_API" ]; then
          JF_KEY_TEST=$($KUBECTL exec -n ${ns} deploy/jellyfin -- \
            ${curl} -s -w "%{http_code}" "http://localhost:8096/System/Info?api_key=$JELLYFIN_API" -o /dev/null 2>/dev/null)
          if [ "$JF_KEY_TEST" != "200" ]; then
            echo "  Jellyfin API key invalid (HTTP $JF_KEY_TEST), recreating..."
            JF_TOKEN=$($KUBECTL exec -n ${ns} deploy/jellyfin -- \
              ${curl} -s -X POST "http://localhost:8096/Users/AuthenticateByName" \
              -H "Content-Type: application/json" \
              -H "X-Emby-Authorization: MediaBrowser Client=\"ArrStack\", Device=\"NixOS\", DeviceId=\"setup\", Version=\"1.0\"" \
              -d "{\"Username\":\"$ADMIN_USER\",\"Pw\":\"$ADMIN_PASSWORD\"}" 2>/dev/null | $JQ -r '.AccessToken // empty' 2>/dev/null || echo "")
            if [ -n "$JF_TOKEN" ]; then
              $KUBECTL exec -n ${ns} deploy/jellyfin -- \
                ${curl} -s -X POST "http://localhost:8096/Auth/Keys?app=ArrStack&api_key=$JF_TOKEN" 2>/dev/null || true
              sleep 2
              JELLYFIN_API=$($KUBECTL exec -n ${ns} deploy/jellyfin -- \
                ${curl} -s "http://localhost:8096/Auth/Keys?api_key=$JF_TOKEN" 2>/dev/null | \
                $JQ -r '.Items[] | select(.AppName == "ArrStack") | .AccessToken' 2>/dev/null || echo "")
              echo "  Jellyfin API key: refreshed"
            fi
          fi
        fi

        update_notification_key() {
          local deploy=$1 port=$2 arr_api=$3 display_name=$4 existing="$5"
          local notif_id current_key updated
          notif_id=$(echo "$existing" | $JQ -r '.id')
          current_key=$(echo "$existing" | $JQ -r '.fields[] | select(.name == "apiKey") | .value')
          if [ "$current_key" != "$JELLYFIN_API" ]; then
            updated=$(echo "$existing" | $JQ '(.fields[] | select(.name == "apiKey")).value = "'"$JELLYFIN_API"'"')
            $KUBECTL exec -n ${ns} deploy/$deploy -- \
              ${curl} -s -X PUT "http://localhost:$port/api/v3/notification/$notif_id" \
              -H "X-Api-Key: $arr_api" \
              -H "Content-Type: application/json" \
              -d "$updated" >/dev/null 2>&1
            echo "  $display_name -> Jellyfin: API key updated"
          else
            echo "  $display_name -> Jellyfin: already configured"
          fi
        }

        # Sonarr -> Jellyfin
        if [ -n "$JELLYFIN_API" ] && wait_for_app_pod "sonarr"; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
            ${curl} -s "http://localhost:8989/api/v3/notification" \
            -H "X-Api-Key: $SONARR_API" 2>/dev/null | $JQ '.[] | select(.name == "Jellyfin")' || echo "")

          if [ -z "$EXISTING" ]; then
            SCHEMA=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
              ${curl} -s "http://localhost:8989/api/v3/notification/schema" \
              -H "X-Api-Key: $SONARR_API" 2>/dev/null | $JQ '.[] | select(.implementation == "MediaBrowser")' || echo "")

            if [ -n "$SCHEMA" ]; then
              NOTIFICATION=$(echo "$SCHEMA" | $JQ '
                .name = "Jellyfin" |
                .onDownload = true |
                .onUpgrade = true |
                .onSeriesDelete = true |
                .onEpisodeFileDelete = true |
                (.fields[] | select(.name == "host")).value = "jellyfin" |
                (.fields[] | select(.name == "port")).value = 8096 |
                (.fields[] | select(.name == "apiKey")).value = "'"$JELLYFIN_API"'" |
                (.fields[] | select(.name == "useSsl")).value = false |
                (.fields[] | select(.name == "updateLibrary")).value = true |
                (.fields[] | select(.name == "mapFrom")).value = "/data/media/" |
                (.fields[] | select(.name == "mapTo")).value = "/data/"
              ')

              RESULT=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
                ${curl} -s -X POST "http://localhost:8989/api/v3/notification" \
                -H "X-Api-Key: $SONARR_API" \
                -H "Content-Type: application/json" \
                -d "$NOTIFICATION" 2>/dev/null)

              if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
                echo "  Sonarr -> Jellyfin: configured"
              else
                echo "  Sonarr -> Jellyfin: Error"
              fi
            fi
          else
            update_notification_key "sonarr" "8989" "$SONARR_API" "Sonarr" "$EXISTING"
          fi
        fi

        # Radarr -> Jellyfin
        if [ -n "$JELLYFIN_API" ] && wait_for_app_pod "radarr"; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/radarr -- \
            ${curl} -s "http://localhost:7878/api/v3/notification" \
            -H "X-Api-Key: $RADARR_API" 2>/dev/null | $JQ '.[] | select(.name == "Jellyfin")' || echo "")

          if [ -z "$EXISTING" ]; then
            SCHEMA=$($KUBECTL exec -n ${ns} deploy/radarr -- \
              ${curl} -s "http://localhost:7878/api/v3/notification/schema" \
              -H "X-Api-Key: $RADARR_API" 2>/dev/null | $JQ '.[] | select(.implementation == "MediaBrowser")' || echo "")

            if [ -n "$SCHEMA" ]; then
              NOTIFICATION=$(echo "$SCHEMA" | $JQ '
                .name = "Jellyfin" |
                .onDownload = true |
                .onUpgrade = true |
                .onMovieDelete = true |
                .onMovieFileDelete = true |
                (.fields[] | select(.name == "host")).value = "jellyfin" |
                (.fields[] | select(.name == "port")).value = 8096 |
                (.fields[] | select(.name == "apiKey")).value = "'"$JELLYFIN_API"'" |
                (.fields[] | select(.name == "useSsl")).value = false |
                (.fields[] | select(.name == "updateLibrary")).value = true |
                (.fields[] | select(.name == "mapFrom")).value = "/data/media/" |
                (.fields[] | select(.name == "mapTo")).value = "/data/"
              ')

              RESULT=$($KUBECTL exec -n ${ns} deploy/radarr -- \
                ${curl} -s -X POST "http://localhost:7878/api/v3/notification" \
                -H "X-Api-Key: $RADARR_API" \
                -H "Content-Type: application/json" \
                -d "$NOTIFICATION" 2>/dev/null)

              if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
                echo "  Radarr -> Jellyfin: configured"
              else
                echo "  Radarr -> Jellyfin: Error"
              fi
            fi
          else
            update_notification_key "radarr" "7878" "$RADARR_API" "Radarr" "$EXISTING"
          fi
        fi

        # Sonarr ES -> Jellyfin
        if [ -n "$JELLYFIN_API" ] && [ -n "$SONARR_ES_API" ] && wait_for_app_pod "sonarr-es"; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/sonarr-es -- \
            ${curl} -s "http://localhost:8989/api/v3/notification" \
            -H "X-Api-Key: $SONARR_ES_API" 2>/dev/null | $JQ '.[] | select(.name == "Jellyfin")' || echo "")

          if [ -z "$EXISTING" ]; then
            SCHEMA=$($KUBECTL exec -n ${ns} deploy/sonarr-es -- \
              ${curl} -s "http://localhost:8989/api/v3/notification/schema" \
              -H "X-Api-Key: $SONARR_ES_API" 2>/dev/null | $JQ '.[] | select(.implementation == "MediaBrowser")' || echo "")
            if [ -n "$SCHEMA" ]; then
              NOTIFICATION=$(echo "$SCHEMA" | $JQ '
                .name = "Jellyfin" | .onDownload = true | .onUpgrade = true |
                .onSeriesDelete = true | .onEpisodeFileDelete = true |
                (.fields[] | select(.name == "host")).value = "jellyfin" |
                (.fields[] | select(.name == "port")).value = 8096 |
                (.fields[] | select(.name == "apiKey")).value = "'"$JELLYFIN_API"'" |
                (.fields[] | select(.name == "useSsl")).value = false |
                (.fields[] | select(.name == "updateLibrary")).value = true |
                (.fields[] | select(.name == "mapFrom")).value = "/data/media/" |
                (.fields[] | select(.name == "mapTo")).value = "/data/"')
              $KUBECTL exec -n ${ns} deploy/sonarr-es -- \
                ${curl} -s -X POST "http://localhost:8989/api/v3/notification" \
                -H "X-Api-Key: $SONARR_ES_API" \
                -H "Content-Type: application/json" -d "$NOTIFICATION" >/dev/null 2>&1
              echo "  Sonarr ES -> Jellyfin: configured"
            fi
          else
            update_notification_key "sonarr-es" "8989" "$SONARR_ES_API" "Sonarr ES" "$EXISTING"
          fi
        fi

        # Radarr ES -> Jellyfin
        if [ -n "$JELLYFIN_API" ] && [ -n "$RADARR_ES_API" ] && wait_for_app_pod "radarr-es"; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/radarr-es -- \
            ${curl} -s "http://localhost:7878/api/v3/notification" \
            -H "X-Api-Key: $RADARR_ES_API" 2>/dev/null | $JQ '.[] | select(.name == "Jellyfin")' || echo "")

          if [ -z "$EXISTING" ]; then
            SCHEMA=$($KUBECTL exec -n ${ns} deploy/radarr-es -- \
              ${curl} -s "http://localhost:7878/api/v3/notification/schema" \
              -H "X-Api-Key: $RADARR_ES_API" 2>/dev/null | $JQ '.[] | select(.implementation == "MediaBrowser")' || echo "")
            if [ -n "$SCHEMA" ]; then
              NOTIFICATION=$(echo "$SCHEMA" | $JQ '
                .name = "Jellyfin" | .onDownload = true | .onUpgrade = true |
                .onMovieDelete = true | .onMovieFileDelete = true |
                (.fields[] | select(.name == "host")).value = "jellyfin" |
                (.fields[] | select(.name == "port")).value = 8096 |
                (.fields[] | select(.name == "apiKey")).value = "'"$JELLYFIN_API"'" |
                (.fields[] | select(.name == "useSsl")).value = false |
                (.fields[] | select(.name == "updateLibrary")).value = true |
                (.fields[] | select(.name == "mapFrom")).value = "/data/media/" |
                (.fields[] | select(.name == "mapTo")).value = "/data/"')
              $KUBECTL exec -n ${ns} deploy/radarr-es -- \
                ${curl} -s -X POST "http://localhost:7878/api/v3/notification" \
                -H "X-Api-Key: $RADARR_ES_API" \
                -H "Content-Type: application/json" -d "$NOTIFICATION" >/dev/null 2>&1
              echo "  Radarr ES -> Jellyfin: configured"
            fi
          else
            update_notification_key "radarr-es" "7878" "$RADARR_ES_API" "Radarr ES" "$EXISTING"
          fi
        fi

        echo ""
        echo "=== Jellyfin integration configured ==="

        create_marker "${markerFile}"
      '';
    };
  };
}
