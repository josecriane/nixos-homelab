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
  markerFile = "/var/lib/arr-download-clients-setup-done";
  curl = "curl";

  qbitCfg = serverConfig.qbittorrent or { };
  qbitMaxActiveDownloads = toString (qbitCfg.maxActiveDownloads or 5);
  qbitMaxActiveTorrents = toString (qbitCfg.maxActiveTorrents or 10);
  qbitMaxActiveUploads = toString (qbitCfg.maxActiveUploads or 3);
in
{
  systemd.services.arr-download-clients-setup = {
    description = "Configure qBittorrent as download client in arr-stack services";
    after = [
      "k3s-apps.target"
      "arr-credentials-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
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

        if wait_for_app_pod "qbittorrent"; then
          sleep 10  # Wait for WebUI to be ready

          # Login to qBittorrent API (try stored password, then default, then temp from logs)
          QBIT_SID=""
          for try_pass in "$QBIT_PASS" "adminadmin"; do
            QBIT_LOGIN=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
              ${curl} -s -c - "http://localhost:8080/api/v2/auth/login" \
              -d "username=admin&password=$try_pass" 2>/dev/null)
            if echo "$QBIT_LOGIN" | grep -q "SID"; then
              QBIT_SID=$(echo "$QBIT_LOGIN" | grep SID | ${pkgs.gawk}/bin/awk '{print $NF}')
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
              QBIT_SID=$(echo "$QBIT_LOGIN" | grep SID | ${pkgs.gawk}/bin/awk '{print $NF}')
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
                "max_active_downloads": ${qbitMaxActiveDownloads},
                "max_active_torrents": ${qbitMaxActiveTorrents},
                "max_active_uploads": ${qbitMaxActiveUploads},
                "slow_torrent_dl_rate_threshold": 2,
                "slow_torrent_inactive_timer": 600,
                "queueing_enabled": true,
                "dont_count_slow_torrents": true,
                "upnp": false,
                "max_ratio_enabled": true,
                "max_ratio": 2.0,
                "max_ratio_act": 0,
                "max_seeding_time_enabled": false,
                "max_seeding_time": -1,
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

        # Helper: add qBittorrent download client to an arr service
        # Usage: add_qbit_client APP PORT API_VERSION API_KEY CATEGORY_FIELD CATEGORY_VALUE [EXTRA_FIELDS]
        add_qbit_client() {
          local app="$1" port="$2" api_ver="$3" api_key="$4" cat_field="$5" cat_value="$6"

          if ! wait_for_app_pod "$app"; then
            echo "  $app: pod not ready, skipping"
            return
          fi

          # Wait for API to be responsive
          local api_ready=false
          for i in $(seq 1 12); do
            if $KUBECTL exec -n ${ns} deploy/$app -- \
              ${curl} -sf "http://localhost:$port/api/$api_ver/system/status" \
              -H "X-Api-Key: $api_key" >/dev/null 2>&1; then
              api_ready=true
              break
            fi
            sleep 5
          done
          if [ "$api_ready" != "true" ]; then
            echo "  $app: API not ready after 60s, skipping"
            return
          fi

          EXISTING=$($KUBECTL exec -n ${ns} deploy/$app -- \
            ${curl} -s "http://localhost:$port/api/$api_ver/downloadclient" \
            -H "X-Api-Key: $api_key" 2>/dev/null | $JQ '.[] | select(.name == "qBittorrent")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  $app: qBittorrent already configured"
            return
          fi

          RESULT=$($KUBECTL exec -n ${ns} deploy/$app -- \
            ${curl} -s -X POST "http://localhost:$port/api/$api_ver/downloadclient" \
            -H "X-Api-Key: $api_key" \
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
                {"name": "'"$cat_field"'", "value": "'"$cat_value"'"},
                {"name": "initialState", "value": 0},
                {"name": "sequentialOrder", "value": false},
                {"name": "firstAndLast", "value": false},
                {"name": "contentLayout", "value": 0}
              ],
              "tags": []
            }' 2>/dev/null)

          if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
            echo "  $app: qBittorrent configured"
          else
            # Retry once after short wait
            sleep 5
            RESULT=$($KUBECTL exec -n ${ns} deploy/$app -- \
              ${curl} -s -X POST "http://localhost:$port/api/$api_ver/downloadclient" \
              -H "X-Api-Key: $api_key" \
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
                  {"name": "'"$cat_field"'", "value": "'"$cat_value"'"},
                  {"name": "initialState", "value": 0},
                  {"name": "sequentialOrder", "value": false},
                  {"name": "firstAndLast", "value": false},
                  {"name": "contentLayout", "value": 0}
                ],
                "tags": []
              }' 2>/dev/null)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  $app: qBittorrent configured (retry)"
            else
              echo "  $app: Error adding qBittorrent - $RESULT"
            fi
          fi
        }

        # Add qBittorrent to Sonarr
        add_qbit_client "sonarr" "8989" "v3" "$SONARR_API" "tvCategory" "tv"

        # Add qBittorrent to Radarr
        add_qbit_client "radarr" "7878" "v3" "$RADARR_API" "movieCategory" "movies"

        # Add qBittorrent to Lidarr (v1 API)
        [ -n "$LIDARR_API" ] && add_qbit_client "lidarr" "8686" "v1" "$LIDARR_API" "musicCategory" "music"

        # Add qBittorrent to Sonarr ES
        [ -n "$SONARR_ES_API" ] && add_qbit_client "sonarr-es" "8989" "v3" "$SONARR_ES_API" "tvCategory" "tv-es"

        # Add qBittorrent to Radarr ES
        [ -n "$RADARR_ES_API" ] && add_qbit_client "radarr-es" "7878" "v3" "$RADARR_ES_API" "movieCategory" "movies-es"

        # Add qBittorrent to Bookshelf (Readarr v1 API)
        [ -n "$BOOKSHELF_API" ] && add_qbit_client "bookshelf" "8787" "v1" "$BOOKSHELF_API" "bookCategory" "books"

        echo ""
        echo "=== Download clients configured ==="
        echo "- qBittorrent preferences (TMM, categories, save_path)"
        echo "- qBittorrent registered in Sonarr, Radarr, Lidarr, Sonarr ES, Radarr ES, Bookshelf"

        create_marker "${markerFile}"
      '';
    };
  };
}
