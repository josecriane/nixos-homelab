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
  markerFile = "/var/lib/arr-prowlarr-sync-setup-done";
  curl = "curl";
in
{
  systemd.services.arr-prowlarr-sync-setup = {
    description = "Configure Prowlarr app sync and indexers";
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
      ExecStart = pkgs.writeShellScript "arr-prowlarr-sync-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        MARKER_FILE="${markerFile}"
        if [ -f "$MARKER_FILE" ]; then
          echo "Prowlarr sync already configured"
          exit 0
        fi

        wait_for_k3s

        echo "Configuring Prowlarr sync and indexers..."

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
        # CONFIGURE PROWLARR SYNC TO APPS
        # ============================================
        echo ""
        echo "=== Configuring Prowlarr to sync indexers ==="

        if wait_for_app_pod "prowlarr"; then
          # Create language tags for indexer routing
          SPANISH_TAG_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
            ${curl} -s "http://localhost:9696/api/v1/tag" \
            -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.label == "spanish") | .id' || echo "")

          if [ -z "$SPANISH_TAG_ID" ]; then
            SPANISH_TAG_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s -X POST "http://localhost:9696/api/v1/tag" \
              -H "X-Api-Key: $PROWLARR_API" \
              -H "Content-Type: application/json" \
              -d '{"label": "spanish"}' 2>/dev/null | $JQ '.id' || echo "")
            echo "  Prowlarr: tag 'spanish' created (id: $SPANISH_TAG_ID)"
          fi

          ENGLISH_TAG_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
            ${curl} -s "http://localhost:9696/api/v1/tag" \
            -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.label == "english") | .id' || echo "")

          if [ -z "$ENGLISH_TAG_ID" ]; then
            ENGLISH_TAG_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s -X POST "http://localhost:9696/api/v1/tag" \
              -H "X-Api-Key: $PROWLARR_API" \
              -H "Content-Type: application/json" \
              -d '{"label": "english"}' 2>/dev/null | $JQ '.id' || echo "")
            echo "  Prowlarr: tag 'english' created (id: $ENGLISH_TAG_ID)"
          fi

          # Add Sonarr to Prowlarr
          EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
            ${curl} -s "http://localhost:9696/api/v1/applications" \
            -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "Sonarr")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  Prowlarr -> Sonarr: already configured"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s -X POST "http://localhost:9696/api/v1/applications" \
              -H "X-Api-Key: $PROWLARR_API" \
              -H "Content-Type: application/json" \
              -d '{
                "name": "Sonarr",
                "syncLevel": "fullSync",
                "implementation": "Sonarr",
                "configContract": "SonarrSettings",
                "fields": [
                  {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                  {"name": "baseUrl", "value": "http://sonarr:8989"},
                  {"name": "apiKey", "value": "'"$SONARR_API"'"},
                  {"name": "syncCategories", "value": [5000,5010,5020,5030,5040,5045,5050,5090]},
                  {"name": "animeSyncCategories", "value": [5070]},
                  {"name": "syncAnimeStandardFormatSearch", "value": true}
                ],
                "tags": ['"$ENGLISH_TAG_ID"']
              }' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Prowlarr -> Sonarr: configured"
            else
              echo "  Prowlarr -> Sonarr: Error - $RESULT"
            fi
          fi

          # Add Radarr to Prowlarr
          EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
            ${curl} -s "http://localhost:9696/api/v1/applications" \
            -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "Radarr")' || echo "")

          if [ -n "$EXISTING" ]; then
            echo "  Prowlarr -> Radarr: already configured"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s -X POST "http://localhost:9696/api/v1/applications" \
              -H "X-Api-Key: $PROWLARR_API" \
              -H "Content-Type: application/json" \
              -d '{
                "name": "Radarr",
                "syncLevel": "fullSync",
                "implementation": "Radarr",
                "configContract": "RadarrSettings",
                "fields": [
                  {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                  {"name": "baseUrl", "value": "http://radarr:7878"},
                  {"name": "apiKey", "value": "'"$RADARR_API"'"},
                  {"name": "syncCategories", "value": [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]}
                ],
                "tags": ['"$ENGLISH_TAG_ID"']
              }' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Prowlarr -> Radarr: configured"
            else
              echo "  Prowlarr -> Radarr: Error - $RESULT"
            fi
          fi

          # Add Lidarr to Prowlarr
          if [ -n "$LIDARR_API" ]; then
            EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s "http://localhost:9696/api/v1/applications" \
              -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "Lidarr")' || echo "")

            if [ -n "$EXISTING" ]; then
              echo "  Prowlarr -> Lidarr: already configured"
            else
              RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                ${curl} -s -X POST "http://localhost:9696/api/v1/applications" \
                -H "X-Api-Key: $PROWLARR_API" \
                -H "Content-Type: application/json" \
                -d '{
                  "name": "Lidarr",
                  "syncLevel": "fullSync",
                  "implementation": "Lidarr",
                  "configContract": "LidarrSettings",
                  "fields": [
                    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                    {"name": "baseUrl", "value": "http://lidarr:8686"},
                    {"name": "apiKey", "value": "'"$LIDARR_API"'"},
                    {"name": "syncCategories", "value": [3000,3010,3020,3030,3040]}
                  ],
                  "tags": ['"$ENGLISH_TAG_ID"']
                }' 2>&1)
              if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
                echo "  Prowlarr -> Lidarr: configured"
              else
                echo "  Prowlarr -> Lidarr: Error - $RESULT"
              fi
            fi
          fi

          # Add Bookshelf to Prowlarr (Bookshelf is a Readarr fork)
          if [ -n "$BOOKSHELF_API" ]; then
            EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s "http://localhost:9696/api/v1/applications" \
              -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "Bookshelf")' || echo "")

            if [ -n "$EXISTING" ]; then
              echo "  Prowlarr -> Bookshelf: already configured"
            else
              RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                ${curl} -s -X POST "http://localhost:9696/api/v1/applications" \
                -H "X-Api-Key: $PROWLARR_API" \
                -H "Content-Type: application/json" \
                -d '{
                  "name": "Bookshelf",
                  "syncLevel": "fullSync",
                  "implementation": "Readarr",
                  "configContract": "ReadarrSettings",
                  "fields": [
                    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                    {"name": "baseUrl", "value": "http://bookshelf:8787"},
                    {"name": "apiKey", "value": "'"$BOOKSHELF_API"'"},
                    {"name": "syncCategories", "value": [7000,7010,7020,7030,7040,7050,7060]}
                  ],
                  "tags": ['"$ENGLISH_TAG_ID"']
                }' 2>&1)
              if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
                echo "  Prowlarr -> Bookshelf: configured"
              else
                echo "  Prowlarr -> Bookshelf: Error - $RESULT"
              fi
            fi
          fi

          # Tag indexers with language tags
          if [ -n "$SPANISH_TAG_ID" ] && [ -n "$ENGLISH_TAG_ID" ]; then
            ALL_INDEXERS=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s "http://localhost:9696/api/v1/indexer" \
              -H "X-Api-Key: $PROWLARR_API" 2>/dev/null)

            for spanish_indexer in "Elitetorrent-wf" "Frozen Layer" "Union Fansub"; do
              INDEXER_ID=$(echo "$ALL_INDEXERS" | $JQ ".[] | select(.name == \"$spanish_indexer\") | .id" 2>/dev/null || echo "")
              if [ -n "$INDEXER_ID" ]; then
                CURRENT_TAGS=$(echo "$ALL_INDEXERS" | $JQ ".[] | select(.id == $INDEXER_ID) | .tags" 2>/dev/null || echo "[]")
                HAS_TAG=$(echo "$CURRENT_TAGS" | $JQ "index($SPANISH_TAG_ID)" 2>/dev/null || echo "null")
                if [ "$HAS_TAG" = "null" ]; then
                  INDEXER_DATA=$(echo "$ALL_INDEXERS" | $JQ ".[] | select(.id == $INDEXER_ID) | .tags += [$SPANISH_TAG_ID]" 2>/dev/null)
                  $KUBECTL exec -n ${ns} deploy/prowlarr -- \
                    ${curl} -s -X PUT "http://localhost:9696/api/v1/indexer/$INDEXER_ID" \
                    -H "X-Api-Key: $PROWLARR_API" \
                    -H "Content-Type: application/json" \
                    -d "$INDEXER_DATA" >/dev/null 2>&1
                  echo "  Prowlarr: $spanish_indexer tagged 'spanish'"
                fi
              fi
            done

            # Tag English indexers with "english" tag
            for english_indexer in "thepiratebay" "1337x" "eztv" "Nyaa.si" "Internet Archive" "MoviesDVDR"; do
              INDEXER_ID=$(echo "$ALL_INDEXERS" | $JQ ".[] | select(.name == \"$english_indexer\") | .id" 2>/dev/null || echo "")
              if [ -n "$INDEXER_ID" ]; then
                CURRENT_TAGS=$(echo "$ALL_INDEXERS" | $JQ ".[] | select(.id == $INDEXER_ID) | .tags" 2>/dev/null || echo "[]")
                HAS_TAG=$(echo "$CURRENT_TAGS" | $JQ "index($ENGLISH_TAG_ID)" 2>/dev/null || echo "null")
                if [ "$HAS_TAG" = "null" ]; then
                  INDEXER_DATA=$(echo "$ALL_INDEXERS" | $JQ ".[] | select(.id == $INDEXER_ID) | .tags += [$ENGLISH_TAG_ID]" 2>/dev/null)
                  $KUBECTL exec -n ${ns} deploy/prowlarr -- \
                    ${curl} -s -X PUT "http://localhost:9696/api/v1/indexer/$INDEXER_ID" \
                    -H "X-Api-Key: $PROWLARR_API" \
                    -H "Content-Type: application/json" \
                    -d "$INDEXER_DATA" >/dev/null 2>&1
                  echo "  Prowlarr: $english_indexer tagged 'english'"
                fi
              fi
            done

            # Add Sonarr ES to Prowlarr (only Spanish indexers via tag)
            if [ -n "$SONARR_ES_API" ]; then
              EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                ${curl} -s "http://localhost:9696/api/v1/applications" \
                -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "Sonarr ES")' || echo "")

              if [ -n "$EXISTING" ]; then
                echo "  Prowlarr -> Sonarr ES: already configured"
              else
                RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                  ${curl} -s -X POST "http://localhost:9696/api/v1/applications" \
                  -H "X-Api-Key: $PROWLARR_API" \
                  -H "Content-Type: application/json" \
                  -d '{
                    "name": "Sonarr ES",
                    "syncLevel": "fullSync",
                    "implementation": "Sonarr",
                    "configContract": "SonarrSettings",
                    "fields": [
                      {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                      {"name": "baseUrl", "value": "http://sonarr-es:8989"},
                      {"name": "apiKey", "value": "'"$SONARR_ES_API"'"},
                      {"name": "syncCategories", "value": [5000,5010,5020,5030,5040,5045,5050,5090]},
                      {"name": "animeSyncCategories", "value": [5070]},
                      {"name": "syncAnimeStandardFormatSearch", "value": true}
                    ],
                    "tags": ['"$SPANISH_TAG_ID"']
                  }' 2>&1)
                if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
                  echo "  Prowlarr -> Sonarr ES: configured"
                else
                  echo "  Prowlarr -> Sonarr ES: Error - $RESULT"
                fi
              fi
            fi

            # Add Radarr ES to Prowlarr (only Spanish indexers via tag)
            if [ -n "$RADARR_ES_API" ]; then
              EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                ${curl} -s "http://localhost:9696/api/v1/applications" \
                -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "Radarr ES")' || echo "")

              if [ -n "$EXISTING" ]; then
                echo "  Prowlarr -> Radarr ES: already configured"
              else
                RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                  ${curl} -s -X POST "http://localhost:9696/api/v1/applications" \
                  -H "X-Api-Key: $PROWLARR_API" \
                  -H "Content-Type: application/json" \
                  -d '{
                    "name": "Radarr ES",
                    "syncLevel": "fullSync",
                    "implementation": "Radarr",
                    "configContract": "RadarrSettings",
                    "fields": [
                      {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                      {"name": "baseUrl", "value": "http://radarr-es:7878"},
                      {"name": "apiKey", "value": "'"$RADARR_ES_API"'"},
                      {"name": "syncCategories", "value": [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]}
                    ],
                    "tags": ['"$SPANISH_TAG_ID"']
                  }' 2>&1)
                if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
                  echo "  Prowlarr -> Radarr ES: configured"
                else
                  echo "  Prowlarr -> Radarr ES: Error - $RESULT"
                fi
              fi
            fi
          fi
        fi

        # ============================================
        # CONFIGURE PROWLARR INDEXERS
        # ============================================
        echo ""
        echo "=== Configuring indexers in Prowlarr ==="

        if wait_for_app_pod "prowlarr"; then
          # Helper to add indexer
          add_indexer() {
            local name=$1
            local definition=$2

            EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s "http://localhost:9696/api/v1/indexer" \
              -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ ".[] | select(.name == \"$name\")" || echo "")

            if [ -n "$EXISTING" ]; then
              echo "  $name: already configured"
              return 0
            fi

            RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s -X POST "http://localhost:9696/api/v1/indexer?forceSave=true" \
              -H "X-Api-Key: $PROWLARR_API" \
              -H "Content-Type: application/json" \
              -d '{
                "name": "'"$name"'",
                "enable": true,
                "priority": 25,
                "appProfileId": 1,
                "implementation": "Cardigann",
                "configContract": "CardigannSettings",
                "fields": [{"name": "definitionFile", "value": "'"$definition"'"}],
                "tags": []
              }' 2>&1)

            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  $name: configured"
            else
              ERROR=$(echo "$RESULT" | $JQ -r '.[0].errorMessage // "unknown error"' 2>/dev/null || echo "error")
              echo "  $name: Error - $ERROR"
            fi
          }

          # Configure FlareSolverr as indexer proxy in Prowlarr (needed for 1337x, EZTV)
          FLARESOLVERR_EXISTS=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
            ${curl} -s "http://localhost:9696/api/v1/indexerProxy" \
            -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "FlareSolverr")' || echo "")

          if [ -z "$FLARESOLVERR_EXISTS" ]; then
            FLARESOLVERR_RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s -X POST "http://localhost:9696/api/v1/indexerProxy" \
              -H "X-Api-Key: $PROWLARR_API" \
              -H "Content-Type: application/json" \
              -d '{
                "name": "FlareSolverr",
                "implementation": "FlareSolverr",
                "configContract": "FlareSolverrSettings",
                "fields": [
                  {"name": "host", "value": "http://flaresolverr:8191"},
                  {"name": "requestTimeout", "value": 60}
                ],
                "tags": []
              }' 2>&1)
            if echo "$FLARESOLVERR_RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Prowlarr: FlareSolverr configured"
            else
              echo "  Prowlarr: FlareSolverr error (may not be ready yet)"
            fi
          else
            echo "  Prowlarr: FlareSolverr already configured"
          fi

          # Get FlareSolverr tag ID for indexers that need it
          FS_TAG_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
            ${curl} -s "http://localhost:9696/api/v1/tag" \
            -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.label == "flaresolverr") | .id' 2>/dev/null || echo "")
          if [ -z "$FS_TAG_ID" ]; then
            FS_TAG_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s -X POST "http://localhost:9696/api/v1/tag" \
              -H "X-Api-Key: $PROWLARR_API" \
              -H "Content-Type: application/json" \
              -d '{"label":"flaresolverr"}' 2>/dev/null | $JQ '.id' 2>/dev/null || echo "")
          fi

          # Assign FlareSolverr tag to proxy if not already tagged
          if [ -n "$FS_TAG_ID" ]; then
            FS_PROXY_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s "http://localhost:9696/api/v1/indexerProxy" \
              -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "FlareSolverr") | .id' 2>/dev/null || echo "")
            if [ -n "$FS_PROXY_ID" ]; then
              FS_PROXY_JSON=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                ${curl} -s "http://localhost:9696/api/v1/indexerProxy/$FS_PROXY_ID" \
                -H "X-Api-Key: $PROWLARR_API" 2>/dev/null)
              HAS_TAG=$(echo "$FS_PROXY_JSON" | $JQ ".tags | index($FS_TAG_ID)" 2>/dev/null)
              if [ "$HAS_TAG" = "null" ] || [ -z "$HAS_TAG" ]; then
                UPDATED=$(echo "$FS_PROXY_JSON" | $JQ ".tags = [$FS_TAG_ID]" 2>/dev/null)
                $KUBECTL exec -n ${ns} deploy/prowlarr -- \
                  ${curl} -s -X PUT "http://localhost:9696/api/v1/indexerProxy/$FS_PROXY_ID" \
                  -H "X-Api-Key: $PROWLARR_API" \
                  -H "Content-Type: application/json" \
                  -d "$UPDATED" >/dev/null 2>&1
                echo "  FlareSolverr proxy: tag assigned"
              fi
            fi
          fi

          # Indexers that need FlareSolverr (Cloudflare-protected sites)
          FLARESOLVERR_INDEXERS="1337x eztv"

          # Add public indexers via Cardigann definitions
          SPANISH_INDEXER_FILES="frozenlayer elitetorrent-wf unionfansub"

          for indexer_def in "thepiratebay:thepiratebay" "1337x:1337x" "eztv:eztv" "Nyaa.si:nyaasi" "Internet Archive:internetarchive" "MoviesDVDR:moviesdvdr" "Frozen Layer:frozenlayer" "Elitetorrent-wf:elitetorrent-wf" "Union Fansub:unionfansub"; do
            IFS=':' read -r indexer_name indexer_file <<< "$indexer_def"

            EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              ${curl} -s "http://localhost:9696/api/v1/indexer" \
              -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ ".[] | select(.name == \"$indexer_name\")" 2>/dev/null || echo "")

            if [ -n "$EXISTING" ]; then
              echo "  $indexer_name: already configured"
            else
              # Determine tags (FlareSolverr + language)
              TAGS="[]"
              if [ -n "$FS_TAG_ID" ] && echo "$FLARESOLVERR_INDEXERS" | grep -qw "$indexer_file"; then
                TAGS=$(echo "$TAGS" | $JQ ". + [$FS_TAG_ID]")
              fi
              if echo "$SPANISH_INDEXER_FILES" | grep -qw "$indexer_file"; then
                [ -n "$SPANISH_TAG_ID" ] && TAGS=$(echo "$TAGS" | $JQ ". + [$SPANISH_TAG_ID]")
              else
                [ -n "$ENGLISH_TAG_ID" ] && TAGS=$(echo "$TAGS" | $JQ ". + [$ENGLISH_TAG_ID]")
              fi

              RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                ${curl} -s -X POST "http://localhost:9696/api/v1/indexer?forceSave=true" \
                -H "X-Api-Key: $PROWLARR_API" \
                -H "Content-Type: application/json" \
                -d '{
                  "name": "'"$indexer_name"'",
                  "enable": true,
                  "priority": 25,
                  "appProfileId": 1,
                  "implementation": "Cardigann",
                  "configContract": "CardigannSettings",
                  "fields": [{"name": "definitionFile", "value": "'"$indexer_file"'"}],
                  "tags": '"$TAGS"'
                }' 2>&1)

              if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
                echo "  $indexer_name: configured"
              else
                # Fallback: insert via SQLite for Cloudflare-protected indexers
                if echo "$FLARESOLVERR_INDEXERS" | grep -qw "$indexer_file"; then
                  echo "  $indexer_name: API failed (Cloudflare), trying SQLite..."
                  PROWLARR_DB=$(ls -d /var/lib/rancher/k3s/storage/pvc-*_media_prowlarr-config/prowlarr.db 2>/dev/null | head -1)
                  if [ -n "$PROWLARR_DB" ]; then
                    # Indexer names (1337x, eztv) don't contain single quotes, safe to use directly
                    ${pkgs.sqlite}/bin/sqlite3 "$PROWLARR_DB" \
                      "INSERT INTO \"Indexers\" (\"Name\",\"Implementation\",\"Settings\",\"ConfigContract\",\"EnableRss\",\"EnableAutomaticSearch\",\"EnableInteractiveSearch\",\"Priority\",\"Added\",\"Tags\",\"AppProfileId\") SELECT '$indexer_name','Cardigann','{\"definitionFile\":\"$indexer_file\",\"baseUrl\":\"\",\"baseSettings\":{\"limitsUnit\":0}}','CardigannSettings',1,1,1,25,datetime('now'),'[$FS_TAG_ID]',1 WHERE NOT EXISTS (SELECT 1 FROM \"Indexers\" WHERE \"Name\"='$indexer_name');" \
                      2>/dev/null && echo "  $indexer_name: configured via SQLite" || echo "  $indexer_name: SQLite also failed"
                  else
                    echo "  $indexer_name: Skipped (DB not found)"
                  fi
                else
                  ERROR=$(echo "$RESULT" | $JQ -r '.[0].errorMessage // .message // "definition not found"' 2>/dev/null || echo "error")
                  echo "  $indexer_name: Skipped ($ERROR)"
                fi
              fi
            fi
          done
          echo "  Indexers will sync automatically to Sonarr/Radarr/Lidarr"
        fi

        echo ""
        echo "=== Prowlarr sync configured ==="
        echo "- Registered apps: Sonarr, Radarr, Lidarr, Bookshelf, Sonarr ES, Radarr ES"
        echo "- Public indexers configured"
        echo "- FlareSolverr proxy for Cloudflare-protected sites"

        create_marker "${markerFile}"
      '';
    };
  };
}
