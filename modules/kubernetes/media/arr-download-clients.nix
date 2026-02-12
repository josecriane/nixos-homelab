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
  markerFile = "/var/lib/arr-download-clients-setup-done";
  curl = "curl";
in
{
  systemd.services.arr-download-clients-setup = {
    description = "Configure qBittorrent as download client in arr-stack services";
    after = [
      "k3s-media.target"
      "arr-credentials-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [ "arr-credentials-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "arr-download-clients-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        MARKER_FILE="${markerFile}"
        if [ -f "$MARKER_FILE" ]; then
          echo "Download clients already configured"
          exit 0
        fi

        wait_for_k3s

        echo "Configuring download clients..."

        # ============================================
        # LOAD ALL CREDENTIALS
        # ============================================
        SONARR_API=$(get_secret_value ${ns} sonarr-credentials API_KEY)
        SONARR_ES_API=$(get_secret_value ${ns} sonarr-es-credentials API_KEY)
        RADARR_API=$(get_secret_value ${ns} radarr-credentials API_KEY)
        RADARR_ES_API=$(get_secret_value ${ns} radarr-es-credentials API_KEY)
        PROWLARR_API=$(get_secret_value ${ns} prowlarr-credentials API_KEY)
        LIDARR_API=$(get_secret_value ${ns} lidarr-credentials API_KEY)
        BOOKSHELF_API=$(get_secret_value ${ns} bookshelf-credentials API_KEY)
        QBIT_PASS=$(get_secret_value ${ns} qbittorrent-credentials PASSWORD)
        BAZARR_API=$(get_secret_value ${ns} bazarr-credentials API_KEY)
        # Fallback: read Bazarr API key from auth section of config
        if [ -z "$BAZARR_API" ]; then
          BAZARR_API=$($KUBECTL exec -n ${ns} deploy/bazarr -- \
            sh -c "sed -n '/^auth:/,/^[a-z]/p' /config/config/config.yaml 2>/dev/null | grep 'apikey:' | head -1 | sed 's/.*apikey: *//' | tr -d ' '" 2>/dev/null || echo "")
        fi

        if [ -z "$SONARR_API" ] || [ -z "$RADARR_API" ] || [ -z "$PROWLARR_API" ]; then
          echo "ERROR: Required credentials not found"
          echo "Run arr-credentials-setup first"
          exit 1
        fi

        # ============================================
        # CONFIGURE QBITTORRENT VIA API
        # ============================================
        echo ""
        echo "=== Configuring qBittorrent ==="

        # Helper function to wait for pod by app label (supports both app= and app.kubernetes.io/name= labels)
        wait_for_app_pod() {
          local app=$1
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

        if wait_for_app_pod "qbittorrent"; then
          sleep 10  # Wait for WebUI to be ready

          # Login to qBittorrent API (try stored password, then default, then temp from logs)
          QBIT_SID=""
          for try_pass in "$QBIT_PASS" "adminadmin"; do
            QBIT_LOGIN=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
              ${curl} -s -c - "http://localhost:8080/api/v2/auth/login" \
              -d "username=admin&password=$try_pass" 2>/dev/null)
            if echo "$QBIT_LOGIN" | grep -q "SID"; then
              QBIT_SID=$(echo "$QBIT_LOGIN" | grep SID | awk '{print $NF}')
              break
            fi
          done

          if [ -z "$QBIT_SID" ]; then
            # Try temporary password from logs
            TEMP_PASS=$($KUBECTL logs -n ${ns} deploy/qbittorrent 2>/dev/null | \
              grep -oP "temporary password is provided.*: \K\S+" | tail -1 || echo "")
            if [ -n "$TEMP_PASS" ]; then
              QBIT_LOGIN=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                ${curl} -s -c - "http://localhost:8080/api/v2/auth/login" \
                -d "username=admin&password=$TEMP_PASS" 2>/dev/null)
              QBIT_SID=$(echo "$QBIT_LOGIN" | grep SID | awk '{print $NF}')
            fi
          fi

          if [ -n "$QBIT_SID" ]; then
            QBIT_COOKIE="-b SID=$QBIT_SID"

            # 1. Set save path, TMM, and queue settings via API
            $KUBECTL exec -n ${ns} deploy/qbittorrent -- \
              ${curl} -s $QBIT_COOKIE "http://localhost:8080/api/v2/app/setPreferences" \
              --data-urlencode 'json={
                "save_path": "/data/torrents",
                "temp_path": "/data/torrents/incomplete",
                "temp_path_enabled": true,
                "auto_tmm_enabled": true,
                "max_active_downloads": 5,
                "max_active_torrents": 10,
                "max_active_uploads": 3,
                "slow_torrent_dl_rate_threshold": 2,
                "slow_torrent_inactive_timer": 600,
                "queueing_enabled": true,
                "dont_count_slow_torrents": true,
                "upnp": false,
                "max_ratio_enabled": true,
                "max_ratio": 1.0,
                "max_ratio_act": 1,
                "max_seeding_time_enabled": true,
                "max_seeding_time": 10080,
                "anonymous_mode": false,
                "encryption": 1,
                "add_trackers_enabled": false
              }' 2>/dev/null
            echo "  qBittorrent: preferences configured (TMM, save_path, queue)"

            # 2. Create categories with save paths (TRaSH Guides structure)
            for cat_def in "tv:/data/torrents/tv" "movies:/data/torrents/movies" "music:/data/torrents/music" "books:/data/torrents/books"; do
              IFS=':' read -r cat_name cat_path <<< "$cat_def"
              $KUBECTL exec -n ${ns} deploy/qbittorrent -- \
                ${curl} -s $QBIT_COOKIE "http://localhost:8080/api/v2/torrents/createCategory" \
                -d "category=$cat_name&savePath=$cat_path" 2>/dev/null
            done
            echo "  qBittorrent: categories created (tv, movies, music, books)"
          else
            echo "  qBittorrent: ERROR - Could not authenticate with the API"
          fi
        fi

        # ============================================
        # CONFIGURE QBITTORRENT AS DOWNLOAD CLIENT
        # ============================================
        echo ""
        echo "=== Configuring qBittorrent as download client ==="

        # Add qBittorrent to Sonarr
        if wait_for_app_pod "sonarr"; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
            ${curl} -s "http://localhost:8989/api/v3/downloadclient" \
            -H "X-Api-Key: $SONARR_API" 2>/dev/null | $JQ '.[] | select(.name == "qBittorrent")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  Sonarr: qBittorrent already configured"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
              ${curl} -s -X POST "http://localhost:8989/api/v3/downloadclient" \
              -H "X-Api-Key: $SONARR_API" \
              -H "Content-Type: application/json" \
              -d '{
                "enable": true,
                "protocol": "torrent",
                "priority": 1,
                "removeCompletedDownloads": true,
                "removeFailedDownloads": true,
                "name": "qBittorrent",
                "implementation": "QBittorrent",
                "configContract": "QBittorrentSettings",
                "fields": [
                  {"name": "host", "value": "qbittorrent"},
                  {"name": "port", "value": 8080},
                  {"name": "useSsl", "value": false},
                  {"name": "urlBase", "value": ""},
                  {"name": "username", "value": "admin"},
                  {"name": "password", "value": "'"$QBIT_PASS"'"},
                  {"name": "tvCategory", "value": "tv"},
                  {"name": "recentTvPriority", "value": 0},
                  {"name": "olderTvPriority", "value": 0},
                  {"name": "initialState", "value": 0},
                  {"name": "sequentialOrder", "value": false},
                  {"name": "firstAndLast", "value": false},
                  {"name": "contentLayout", "value": 0}
                ],
                "tags": []
              }' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Sonarr: qBittorrent configured"
            else
              echo "  Sonarr: Error - $RESULT"
            fi
          fi
        fi

        # Add qBittorrent to Radarr
        if wait_for_app_pod "radarr"; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/radarr -- \
            ${curl} -s "http://localhost:7878/api/v3/downloadclient" \
            -H "X-Api-Key: $RADARR_API" 2>/dev/null | $JQ '.[] | select(.name == "qBittorrent")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  Radarr: qBittorrent already configured"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/radarr -- \
              ${curl} -s -X POST "http://localhost:7878/api/v3/downloadclient" \
              -H "X-Api-Key: $RADARR_API" \
              -H "Content-Type: application/json" \
              -d '{
                "enable": true,
                "protocol": "torrent",
                "priority": 1,
                "removeCompletedDownloads": true,
                "removeFailedDownloads": true,
                "name": "qBittorrent",
                "implementation": "QBittorrent",
                "configContract": "QBittorrentSettings",
                "fields": [
                  {"name": "host", "value": "qbittorrent"},
                  {"name": "port", "value": 8080},
                  {"name": "useSsl", "value": false},
                  {"name": "urlBase", "value": ""},
                  {"name": "username", "value": "admin"},
                  {"name": "password", "value": "'"$QBIT_PASS"'"},
                  {"name": "movieCategory", "value": "movies"},
                  {"name": "recentMoviePriority", "value": 0},
                  {"name": "olderMoviePriority", "value": 0},
                  {"name": "initialState", "value": 0},
                  {"name": "sequentialOrder", "value": false},
                  {"name": "firstAndLast", "value": false},
                  {"name": "contentLayout", "value": 0}
                ],
                "tags": []
              }' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Radarr: qBittorrent configured"
            else
              echo "  Radarr: Error - $RESULT"
            fi
          fi
        fi

        # Add qBittorrent to Lidarr (uses v1 API)
        if wait_for_app_pod "lidarr" && [ -n "$LIDARR_API" ]; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
            ${curl} -s "http://localhost:8686/api/v1/downloadclient" \
            -H "X-Api-Key: $LIDARR_API" 2>/dev/null | $JQ '.[] | select(.name == "qBittorrent")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  Lidarr: qBittorrent already configured"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
              ${curl} -s -X POST "http://localhost:8686/api/v1/downloadclient" \
              -H "X-Api-Key: $LIDARR_API" \
              -H "Content-Type: application/json" \
              -d '{
                "enable": true,
                "protocol": "torrent",
                "priority": 1,
                "removeCompletedDownloads": true,
                "removeFailedDownloads": true,
                "name": "qBittorrent",
                "implementation": "QBittorrent",
                "configContract": "QBittorrentSettings",
                "fields": [
                  {"name": "host", "value": "qbittorrent"},
                  {"name": "port", "value": 8080},
                  {"name": "useSsl", "value": false},
                  {"name": "urlBase", "value": ""},
                  {"name": "username", "value": "admin"},
                  {"name": "password", "value": "'"$QBIT_PASS"'"},
                  {"name": "musicCategory", "value": "music"},
                  {"name": "recentMusicPriority", "value": 0},
                  {"name": "olderMusicPriority", "value": 0},
                  {"name": "initialState", "value": 0},
                  {"name": "sequentialOrder", "value": false},
                  {"name": "firstAndLast", "value": false},
                  {"name": "contentLayout", "value": 0}
                ],
                "tags": []
              }' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Lidarr: qBittorrent configured"
            else
              echo "  Lidarr: Error - $RESULT"
            fi
          fi
        fi

        # Add qBittorrent to Sonarr ES
        if wait_for_app_pod "sonarr-es" && [ -n "$SONARR_ES_API" ]; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/sonarr-es -- \
            ${curl} -s "http://localhost:8989/api/v3/downloadclient" \
            -H "X-Api-Key: $SONARR_ES_API" 2>/dev/null | $JQ '.[] | select(.name == "qBittorrent")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  Sonarr ES: qBittorrent already configured"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/sonarr-es -- \
              ${curl} -s -X POST "http://localhost:8989/api/v3/downloadclient" \
              -H "X-Api-Key: $SONARR_ES_API" \
              -H "Content-Type: application/json" \
              -d '{
                "enable": true, "protocol": "torrent", "priority": 1,
                "removeCompletedDownloads": true, "removeFailedDownloads": true,
                "name": "qBittorrent", "implementation": "QBittorrent", "configContract": "QBittorrentSettings",
                "fields": [
                  {"name": "host", "value": "qbittorrent"}, {"name": "port", "value": 8080},
                  {"name": "useSsl", "value": false}, {"name": "urlBase", "value": ""},
                  {"name": "username", "value": "admin"}, {"name": "password", "value": "'"$QBIT_PASS"'"},
                  {"name": "tvCategory", "value": "tv-es"}, {"name": "recentTvPriority", "value": 0},
                  {"name": "olderTvPriority", "value": 0}, {"name": "initialState", "value": 0},
                  {"name": "sequentialOrder", "value": false}, {"name": "firstAndLast", "value": false},
                  {"name": "contentLayout", "value": 0}
                ], "tags": []
              }' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Sonarr ES: qBittorrent configured"
            else
              echo "  Sonarr ES: Error - $RESULT"
            fi
          fi
        fi

        # Add qBittorrent to Radarr ES
        if wait_for_app_pod "radarr-es" && [ -n "$RADARR_ES_API" ]; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/radarr-es -- \
            ${curl} -s "http://localhost:7878/api/v3/downloadclient" \
            -H "X-Api-Key: $RADARR_ES_API" 2>/dev/null | $JQ '.[] | select(.name == "qBittorrent")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  Radarr ES: qBittorrent already configured"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/radarr-es -- \
              ${curl} -s -X POST "http://localhost:7878/api/v3/downloadclient" \
              -H "X-Api-Key: $RADARR_ES_API" \
              -H "Content-Type: application/json" \
              -d '{
                "enable": true, "protocol": "torrent", "priority": 1,
                "removeCompletedDownloads": true, "removeFailedDownloads": true,
                "name": "qBittorrent", "implementation": "QBittorrent", "configContract": "QBittorrentSettings",
                "fields": [
                  {"name": "host", "value": "qbittorrent"}, {"name": "port", "value": 8080},
                  {"name": "useSsl", "value": false}, {"name": "urlBase", "value": ""},
                  {"name": "username", "value": "admin"}, {"name": "password", "value": "'"$QBIT_PASS"'"},
                  {"name": "movieCategory", "value": "movies-es"}, {"name": "recentMoviePriority", "value": 0},
                  {"name": "olderMoviePriority", "value": 0}, {"name": "initialState", "value": 0},
                  {"name": "sequentialOrder", "value": false}, {"name": "firstAndLast", "value": false},
                  {"name": "contentLayout", "value": 0}
                ], "tags": []
              }' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Radarr ES: qBittorrent configured"
            else
              echo "  Radarr ES: Error - $RESULT"
            fi
          fi
        fi

        # Add qBittorrent to Bookshelf (Readarr v1 API)
        if wait_for_app_pod "bookshelf" && [ -n "$BOOKSHELF_API" ]; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/bookshelf -- \
            ${curl} -s "http://localhost:8787/api/v1/downloadclient" \
            -H "X-Api-Key: $BOOKSHELF_API" 2>/dev/null | $JQ '.[] | select(.name == "qBittorrent")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  Bookshelf: qBittorrent already configured"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/bookshelf -- \
              ${curl} -s -X POST "http://localhost:8787/api/v1/downloadclient" \
              -H "X-Api-Key: $BOOKSHELF_API" \
              -H "Content-Type: application/json" \
              -d '{
                "enable": true,
                "protocol": "torrent",
                "priority": 1,
                "removeCompletedDownloads": true,
                "removeFailedDownloads": true,
                "name": "qBittorrent",
                "implementation": "QBittorrent",
                "configContract": "QBittorrentSettings",
                "fields": [
                  {"name": "host", "value": "qbittorrent"},
                  {"name": "port", "value": 8080},
                  {"name": "useSsl", "value": false},
                  {"name": "urlBase", "value": ""},
                  {"name": "username", "value": "admin"},
                  {"name": "password", "value": "'"$QBIT_PASS"'"},
                  {"name": "bookCategory", "value": "books"},
                  {"name": "recentBookPriority", "value": 0},
                  {"name": "olderBookPriority", "value": 0},
                  {"name": "initialState", "value": 0},
                  {"name": "sequentialOrder", "value": false},
                  {"name": "firstAndLast", "value": false},
                  {"name": "contentLayout", "value": 0}
                ],
                "tags": []
              }' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Bookshelf: qBittorrent configured"
            else
              echo "  Bookshelf: Error - $RESULT"
            fi
          fi
        fi

        echo ""
        echo "=== Download clients configured ==="
        echo "- qBittorrent preferences (TMM, categories, save_path)"
        echo "- qBittorrent registered in Sonarr, Radarr, Lidarr, Sonarr ES, Radarr ES, Bookshelf"

        create_marker "${markerFile}"
      '';
    };
  };
}
