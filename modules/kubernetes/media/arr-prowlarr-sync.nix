{
  k8s,
  lib,
  pkgs,
  ...
}:

let
  arr = import ./arr-lib.nix { inherit lib; };
  ns = arr.ns;
  markerFile = "/var/lib/arr-prowlarr-sync-setup-done";
  migratorPodYaml = ./_migrator-pod.yaml;

  syncCategories = {
    tv = [
      5000
      5010
      5020
      5030
      5040
      5045
      5050
      5090
    ];
    movies = [
      2000
      2010
      2020
      2030
      2040
      2045
      2050
      2060
      2070
      2080
      2090
    ];
    music = [
      3000
      3010
      3020
      3030
      3040
    ];
    books = [
      7000
      7010
      7020
      7030
      7040
      7050
      7060
    ];
  };

  apps = [
    {
      name = "Sonarr";
      app = "sonarr";
      implementation = "Sonarr";
      port = 8989;
      categories = syncCategories.tv;
      anime = true;
      tag = "english";
    }
    {
      name = "Radarr";
      app = "radarr";
      implementation = "Radarr";
      port = 7878;
      categories = syncCategories.movies;
      tag = "english";
    }
    {
      name = "Lidarr";
      app = "lidarr";
      implementation = "Lidarr";
      port = 8686;
      categories = syncCategories.music;
      tag = "english";
    }
    {
      name = "Bookshelf";
      app = "bookshelf";
      implementation = "Readarr";
      port = 8787;
      categories = syncCategories.books;
      tag = "english";
    }
    {
      name = "Sonarr ES";
      app = "sonarr-es";
      implementation = "Sonarr";
      port = 8989;
      categories = syncCategories.tv;
      anime = true;
      tag = "spanish";
    }
    {
      name = "Radarr ES";
      app = "radarr-es";
      implementation = "Radarr";
      port = 7878;
      categories = syncCategories.movies;
      tag = "spanish";
    }
  ];

  registerApp =
    entry:
    let
      tagVar = "${lib.toUpper entry.tag}_TAG_ID";
    in
    ''
      register_app ${lib.escapeShellArg entry.name} ${entry.app} ${entry.implementation} ${toString entry.port} \
        ${lib.escapeShellArg (builtins.toJSON entry.categories)} ${
          if entry.anime or false then "true" else "false"
        } "''$${tagVar}"'';
in
{
  systemd.services.arr-prowlarr-sync-setup = {
    description = "Configure Prowlarr to sync indexers with arr-stack apps";
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
      ExecStart = pkgs.writeShellScript "arr-prowlarr-sync-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        setup_preamble "${markerFile}" "Prowlarr sync"
        wait_for_k3s

        ${arr.helpers}

        # ============================================
        # LOAD ALL CREDENTIALS
        # ============================================
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


        echo ""
        echo "=== Configuring Prowlarr to sync indexers ==="

        if ! arr_usable prowlarr; then
          create_marker "${markerFile}"
          exit 0
        fi

        ensure_tag() {
          local label="$1" id
          id=$(arr_get prowlarr tag | $JQ -r --arg l "$label" '.[] | select(.label == $l) | .id' 2>/dev/null | head -1)
          if [ -z "$id" ]; then
            id=$(arr_post prowlarr tag "{\"label\": \"$label\"}" | $JQ -r '.id // empty' 2>/dev/null)
            echo "  Prowlarr: tag '$label' created (id: $id)" >&2
          fi
          printf '%s' "$id"
        }

        SPANISH_TAG_ID=$(ensure_tag spanish)
        ENGLISH_TAG_ID=$(ensure_tag english)

        register_app() {
          local name="$1" app="$2" implementation="$3" port="$4" categories="$5" anime="$6" tag="$7"
          local payload

          if [ -z "$(arr_stable_key "$app")" ] && [ -z "$(arr_key "$app")" ]; then
            echo "  Prowlarr -> $name: no API key, skipped"
            return 0
          fi

          payload=$($JQ -n \
            --arg name "$name" \
            --arg implementation "$implementation" \
            --arg baseUrl "http://$app:$port" \
            --arg apiKey "$(arr_key "$app")" \
            --argjson categories "$categories" \
            --argjson anime "$anime" \
            --argjson tag "''${tag:-0}" '
            {
              name: $name,
              syncLevel: "fullSync",
              implementation: $implementation,
              configContract: ($implementation + "Settings"),
              fields: (
                [
                  {name: "prowlarrUrl", value: "http://prowlarr:9696"},
                  {name: "baseUrl", value: $baseUrl},
                  {name: "apiKey", value: $apiKey},
                  {name: "syncCategories", value: $categories}
                ]
                + (if $anime then
                     [{name: "animeSyncCategories", value: [5070]},
                      {name: "syncAnimeStandardFormatSearch", value: true}]
                   else [] end)
              ),
              tags: [$tag]
            }')

          arr_ensure prowlarr applications "$payload" \
            ".[] | select(.name == \"$name\")" "app $name"
        }

        ${lib.concatMapStringsSep "\n        " registerApp apps}

        echo ""
        echo "=== Configuring indexers in Prowlarr ==="

          # Helper to add indexer
          add_indexer() {
            local name=$1
            local definition=$2

            EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              curl -s "http://localhost:9696/api/v1/indexer" \
              -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ ".[] | select(.name == \"$name\")" || echo "")

            if [ -n "$EXISTING" ]; then
              echo "  $name: already configured"
              return 0
            fi

            RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              curl -s -X POST "http://localhost:9696/api/v1/indexer?forceSave=true" \
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
              }' 2>/dev/null)

            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  $name: configured"
            else
              ERROR=$(echo "$RESULT" | $JQ -r '.[0].errorMessage // "unknown error"' 2>/dev/null || echo "error")
              echo "  $name: Error - $ERROR"
            fi
          }

          # Configure FlareSolverr as indexer proxy in Prowlarr (needed for 1337x, EZTV)
          FLARESOLVERR_EXISTS=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
            curl -s "http://localhost:9696/api/v1/indexerProxy" \
            -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "FlareSolverr")' || echo "")

          if [ -z "$FLARESOLVERR_EXISTS" ]; then
            FLARESOLVERR_RESULT=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              curl -s -X POST "http://localhost:9696/api/v1/indexerProxy" \
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
              }' 2>/dev/null)
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
            curl -s "http://localhost:9696/api/v1/tag" \
            -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.label == "flaresolverr") | .id' 2>/dev/null || echo "")
          if [ -z "$FS_TAG_ID" ]; then
            FS_TAG_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              curl -s -X POST "http://localhost:9696/api/v1/tag" \
              -H "X-Api-Key: $PROWLARR_API" \
              -H "Content-Type: application/json" \
              -d '{"label":"flaresolverr"}' 2>/dev/null | $JQ '.id' 2>/dev/null || echo "")
          fi

          # Assign FlareSolverr tag to proxy if not already tagged
          if [ -n "$FS_TAG_ID" ]; then
            FS_PROXY_ID=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              curl -s "http://localhost:9696/api/v1/indexerProxy" \
              -H "X-Api-Key: $PROWLARR_API" 2>/dev/null | $JQ '.[] | select(.name == "FlareSolverr") | .id' 2>/dev/null || echo "")
            if [ -n "$FS_PROXY_ID" ]; then
              FS_PROXY_JSON=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
                curl -s "http://localhost:9696/api/v1/indexerProxy/$FS_PROXY_ID" \
                -H "X-Api-Key: $PROWLARR_API" 2>/dev/null)
              HAS_TAG=$(echo "$FS_PROXY_JSON" | $JQ ".tags | index($FS_TAG_ID)" 2>/dev/null)
              if [ "$HAS_TAG" = "null" ] || [ -z "$HAS_TAG" ]; then
                UPDATED=$(echo "$FS_PROXY_JSON" | $JQ ".tags = [$FS_TAG_ID]" 2>/dev/null)
                $KUBECTL exec -n ${ns} deploy/prowlarr -- \
                  curl -s -X PUT "http://localhost:9696/api/v1/indexerProxy/$FS_PROXY_ID" \
                  -H "X-Api-Key: $PROWLARR_API" \
                  -H "Content-Type: application/json" \
                  -d "$UPDATED" >/dev/null 2>&1
                echo "  FlareSolverr proxy: tag assigned"
              fi
            fi
          fi

          PENDING_SQL=$(mktemp)

          # Indexers that need FlareSolverr (Cloudflare-protected sites)
          FLARESOLVERR_INDEXERS="1337x eztv"

          # Add public indexers via Cardigann definitions
          SPANISH_INDEXER_FILES="frozenlayer elitetorrent-wf unionfansub"

          for indexer_def in "thepiratebay:thepiratebay" "1337x:1337x" "eztv:eztv" "Nyaa.si:nyaasi" "Internet Archive:internetarchive" "MoviesDVDR:moviesdvdr" "Frozen Layer:frozenlayer" "Elitetorrent-wf:elitetorrent-wf" "Union Fansub:unionfansub"; do
            IFS=':' read -r indexer_name indexer_file <<< "$indexer_def"

            EXISTING=$($KUBECTL exec -n ${ns} deploy/prowlarr -- \
              curl -s "http://localhost:9696/api/v1/indexer" \
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
                curl -s -X POST "http://localhost:9696/api/v1/indexer?forceSave=true" \
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
                }' 2>/dev/null)

              if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
                echo "  $indexer_name: configured"
              else
                # Fallback: queue SQL insert (API rejects indexers it can't reach during test)
                echo "  $indexer_name: API failed, queuing SQL insert..."
                TAGS_SQL=$(echo "$TAGS" | tr -d ' ')
                echo "INSERT INTO Indexers (Name, Implementation, Settings, ConfigContract, Enable, Priority, Added, Redirect, AppProfileId, Tags, DownloadClientId) SELECT '$indexer_name','Cardigann','{\"definitionFile\":\"$indexer_file\"}','CardigannSettings',1,25,datetime('now'),0,1,'$TAGS_SQL',0 WHERE NOT EXISTS (SELECT 1 FROM Indexers WHERE Name='$indexer_name');" >> "$PENDING_SQL"
              fi
            fi
          done

          # Apply queued SQL fallbacks via migrator pod (no hostPath dependency)
          if [ -s "$PENDING_SQL" ]; then
            echo "  Applying $(wc -l < "$PENDING_SQL") SQL fallback(s) to prowlarr.db..."
            $KUBECTL scale deploy -n ${ns} prowlarr --replicas=0 2>/dev/null
            for i in $(seq 1 30); do
              REMAINING=$($KUBECTL get pods -n ${ns} -l app=prowlarr --no-headers 2>/dev/null | wc -l)
              [ "$REMAINING" -eq 0 ] && break
              sleep 2
            done
            sleep 2

            MIGRATOR_POD="prowlarr-migrator-$$"
            ${pkgs.gnused}/bin/sed \
              -e "s|__POD_NAME__|$MIGRATOR_POD|g" \
              -e "s|__NAMESPACE__|${ns}|g" \
              -e "s|__PVC_NAME__|prowlarr-config|g" \
              ${migratorPodYaml} | $KUBECTL apply -f - >/dev/null

            $KUBECTL wait --for=condition=ready "pod/$MIGRATOR_POD" -n ${ns} --timeout=120s

            PROWLARR_DB_PATH=$($KUBECTL exec -n ${ns} "$MIGRATOR_POD" -- find /config -name "prowlarr.db" 2>/dev/null | head -1)
            if [ -n "$PROWLARR_DB_PATH" ]; then
              TMP_DB=$(mktemp)
              $KUBECTL cp "${ns}/$MIGRATOR_POD:$PROWLARR_DB_PATH" "$TMP_DB"
              ${pkgs.sqlite}/bin/sqlite3 "$TMP_DB" < "$PENDING_SQL" 2>/dev/null \
                && echo "  SQL fallbacks applied" \
                || echo "  SQL fallbacks failed"
              $KUBECTL cp "$TMP_DB" "${ns}/$MIGRATOR_POD:$PROWLARR_DB_PATH"
              rm -f "$TMP_DB"
            else
              echo "  prowlarr.db not found in PVC"
            fi

            $KUBECTL delete "pod/$MIGRATOR_POD" -n ${ns} --wait --timeout=60s >/dev/null 2>&1 || true

            $KUBECTL scale deploy -n ${ns} prowlarr --replicas=1 2>/dev/null
            $KUBECTL rollout status -n ${ns} deploy/prowlarr --timeout=120s 2>/dev/null
          fi
          rm -f "$PENDING_SQL"

          echo "  Indexers will sync automatically to Sonarr/Radarr/Lidarr"

        echo ""
        echo "=== Prowlarr sync configured ==="
        create_marker "${markerFile}"
      '';
    };
  };
}
