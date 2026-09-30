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
  markerFile = "/var/lib/arr-download-clients-setup-done";

  qbitCfg = config.homelab.qbittorrent;
  qbitMaxActiveDownloads = toString (qbitCfg.maxActiveDownloads or 5);
  qbitMaxActiveTorrents = toString (qbitCfg.maxActiveTorrents or 10);
  qbitMaxActiveUploads = toString (qbitCfg.maxActiveUploads or 3);

  clients = [
    {
      app = "sonarr";
      field = "tvCategory";
      category = "tv";
    }
    {
      app = "radarr";
      field = "movieCategory";
      category = "movies";
    }
    {
      app = "lidarr";
      field = "musicCategory";
      category = "music";
    }
    {
      app = "sonarr-es";
      field = "tvCategory";
      category = "tv-es";
    }
    {
      app = "radarr-es";
      field = "movieCategory";
      category = "movies-es";
    }
    {
      app = "bookshelf";
      field = "bookCategory";
      category = "books";
    }
  ];

  addClient = c: "add_qbit_client ${c.app} ${c.field} ${c.category}";
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

        setup_preamble "${markerFile}" "Download clients"
        wait_for_k3s

        ${arr.helpers}

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
        if arr_ready qbittorrent; then
          sleep 10  # Wait for WebUI to be ready

          # Login to qBittorrent API (try stored password, then default, then temp from logs)
          QBIT_SID=""
          for try_pass in "$QBIT_PASS" "adminadmin"; do
            QBIT_LOGIN=$($KUBECTL exec -n ${ns} deploy/qbittorrent -- \
              curl -s -c - "http://localhost:8080/api/v2/auth/login" \
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
                curl -s -c - "http://localhost:8080/api/v2/auth/login" \
                -d "username=admin&password=$TEMP_PASS" 2>/dev/null)
              QBIT_SID=$(echo "$QBIT_LOGIN" | grep SID | ${pkgs.gawk}/bin/awk '{print $NF}')
            fi
          fi

          if [ -n "$QBIT_SID" ]; then
            QBIT_COOKIE="-b SID=$QBIT_SID"

            # 1. Set save path, TMM, and queue settings via API
            $KUBECTL exec -n ${ns} deploy/qbittorrent -- \
              curl -s $QBIT_COOKIE "http://localhost:8080/api/v2/app/setPreferences" \
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
                curl -s $QBIT_COOKIE "http://localhost:8080/api/v2/torrents/createCategory" \
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
        add_qbit_client() {
          local app="$1" cat_field="$2" cat_value="$3" label payload existing result
          label=$(arr_label "$app")

          arr_usable "$app" || return 0
          if ! arr_api_ready "$app"; then
            echo "  $label: API not ready after 60s, skipped"
            return 0
          fi

          existing=$(arr_get "$app" downloadclient | $JQ '.[] | select(.name == "qBittorrent")' 2>/dev/null || echo "")
          if [ -n "$existing" ]; then
            echo "  $label: qBittorrent already configured"
            return 0
          fi

          payload=$($JQ -n \
            --arg pass "$QBIT_PASS" \
            --arg field "$cat_field" \
            --arg category "$cat_value" \
            '{
              enable: true,
              protocol: "torrent",
              priority: 1,
              removeCompletedDownloads: true,
              removeFailedDownloads: true,
              name: "qBittorrent",
              implementation: "QBittorrent",
              configContract: "QBittorrentSettings",
              fields: [
                {name: "host", value: "qbittorrent"},
                {name: "port", value: 8080},
                {name: "useSsl", value: false},
                {name: "urlBase", value: ""},
                {name: "username", value: "admin"},
                {name: "password", value: $pass},
                {name: $field, value: $category},
                {name: "initialState", value: 0},
                {name: "sequentialOrder", value: false},
                {name: "firstAndLast", value: false},
                {name: "contentLayout", value: 0}
              ],
              tags: []
            }')

          result=$(arr_post "$app" downloadclient "$payload")
          if ! echo "$result" | $JQ -e '.id' >/dev/null 2>&1; then
            sleep 5
            result=$(arr_post "$app" downloadclient "$payload")
          fi

          if echo "$result" | $JQ -e '.id' >/dev/null 2>&1; then
            echo "  $label: qBittorrent configured"
          else
            echo "  $label: error adding qBittorrent - $(arr_error_of "$result")"
          fi
        }

        ${lib.concatMapStringsSep "\n        " addClient clients}

        echo ""
        echo "=== Download clients configured ==="

        create_marker "${markerFile}"
      '';
    };
  };
}
