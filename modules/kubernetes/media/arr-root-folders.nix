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
  markerFile = "/var/lib/arr-root-folders-setup-done";
  curl = "curl";
in
{
  systemd.services.arr-root-folders-setup = {
    description = "Configure root folders for arr-stack services";
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
      ExecStart = pkgs.writeShellScript "arr-root-folders-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        MARKER_FILE="${markerFile}"
        if [ -f "$MARKER_FILE" ]; then
          echo "Root folders already configured"
          exit 0
        fi

        wait_for_k3s

        echo "Configuring root folders..."

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

        SONARR_API=$(get_secret_value ${ns} sonarr-credentials API_KEY)
        SONARR_ES_API=$(get_secret_value ${ns} sonarr-es-credentials API_KEY)
        RADARR_API=$(get_secret_value ${ns} radarr-credentials API_KEY)
        RADARR_ES_API=$(get_secret_value ${ns} radarr-es-credentials API_KEY)
        LIDARR_API=$(get_secret_value ${ns} lidarr-credentials API_KEY)
        BOOKSHELF_API=$(get_secret_value ${ns} bookshelf-credentials API_KEY)

        if [ -z "$SONARR_API" ] || [ -z "$RADARR_API" ]; then
          echo "ERROR: Required credentials not found"
          exit 1
        fi

        # Sonarr: /data/media/tv
        if wait_for_app_pod "sonarr"; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
            ${curl} -s "http://localhost:8989/api/v3/rootfolder" \
            -H "X-Api-Key: $SONARR_API" 2>/dev/null | $JQ '.[] | select(.path == "/data/media/tv")' || echo "")

          if [ -z "$EXISTING" ]; then
            RESULT=$($KUBECTL exec -n ${ns} deploy/sonarr -- \
              ${curl} -s -X POST "http://localhost:8989/api/v3/rootfolder" \
              -H "X-Api-Key: $SONARR_API" \
              -H "Content-Type: application/json" \
              -d '{"path": "/data/media/tv"}' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Sonarr: /data/media/tv configured"
            else
              echo "  Sonarr: Error - $(echo "$RESULT" | $JQ -r '.[0].errorMessage // "unknown error"')"
            fi
          else
            echo "  Sonarr: /data/media/tv already configured"
          fi
        fi

        # Radarr: /data/media/movies
        if wait_for_app_pod "radarr"; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/radarr -- \
            ${curl} -s "http://localhost:7878/api/v3/rootfolder" \
            -H "X-Api-Key: $RADARR_API" 2>/dev/null | $JQ '.[] | select(.path == "/data/media/movies")' || echo "")

          if [ -z "$EXISTING" ]; then
            RESULT=$($KUBECTL exec -n ${ns} deploy/radarr -- \
              ${curl} -s -X POST "http://localhost:7878/api/v3/rootfolder" \
              -H "X-Api-Key: $RADARR_API" \
              -H "Content-Type: application/json" \
              -d '{"path": "/data/media/movies"}' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Radarr: /data/media/movies configured"
            else
              echo "  Radarr: Error - $(echo "$RESULT" | $JQ -r '.[0].errorMessage // "unknown error"')"
            fi
          else
            echo "  Radarr: /data/media/movies already configured"
          fi
        fi

        # Lidarr: /data/media/music
        if wait_for_app_pod "lidarr" && [ -n "$LIDARR_API" ]; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
            ${curl} -s "http://localhost:8686/api/v1/rootfolder" \
            -H "X-Api-Key: $LIDARR_API" 2>/dev/null | $JQ '.[] | select(.path == "/data/media/music")' || echo "")

          if [ -z "$EXISTING" ]; then
            RESULT=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
              ${curl} -s -X POST "http://localhost:8686/api/v1/rootfolder" \
              -H "X-Api-Key: $LIDARR_API" \
              -H "Content-Type: application/json" \
              -d '{"path": "/data/media/music", "name": "Music", "defaultMetadataProfileId": 1, "defaultQualityProfileId": 3}' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Lidarr: /data/media/music configured (Quality: Standard, Metadata: Standard)"
            else
              echo "  Lidarr: Error - $(echo "$RESULT" | $JQ -r '.[0].errorMessage // "unknown error"')"
            fi
          else
            echo "  Lidarr: /data/media/music already configured"
          fi
        fi

        # Sonarr ES: /data/media/tv-es
        if wait_for_app_pod "sonarr-es" && [ -n "$SONARR_ES_API" ]; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/sonarr-es -- \
            ${curl} -s "http://localhost:8989/api/v3/rootfolder" \
            -H "X-Api-Key: $SONARR_ES_API" 2>/dev/null | $JQ '.[] | select(.path == "/data/media/tv-es")' || echo "")

          if [ -z "$EXISTING" ]; then
            RESULT=$($KUBECTL exec -n ${ns} deploy/sonarr-es -- \
              ${curl} -s -X POST "http://localhost:8989/api/v3/rootfolder" \
              -H "X-Api-Key: $SONARR_ES_API" \
              -H "Content-Type: application/json" \
              -d '{"path": "/data/media/tv-es"}' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Sonarr ES: /data/media/tv-es configured"
            else
              echo "  Sonarr ES: Error - $(echo "$RESULT" | $JQ -r '.[0].errorMessage // "unknown error"')"
            fi
          else
            echo "  Sonarr ES: /data/media/tv-es already configured"
          fi
        fi

        # Radarr ES: /data/media/movies-es
        if wait_for_app_pod "radarr-es" && [ -n "$RADARR_ES_API" ]; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/radarr-es -- \
            ${curl} -s "http://localhost:7878/api/v3/rootfolder" \
            -H "X-Api-Key: $RADARR_ES_API" 2>/dev/null | $JQ '.[] | select(.path == "/data/media/movies-es")' || echo "")

          if [ -z "$EXISTING" ]; then
            RESULT=$($KUBECTL exec -n ${ns} deploy/radarr-es -- \
              ${curl} -s -X POST "http://localhost:7878/api/v3/rootfolder" \
              -H "X-Api-Key: $RADARR_ES_API" \
              -H "Content-Type: application/json" \
              -d '{"path": "/data/media/movies-es"}' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Radarr ES: /data/media/movies-es configured"
            else
              echo "  Radarr ES: Error - $(echo "$RESULT" | $JQ -r '.[0].errorMessage // "unknown error"')"
            fi
          else
            echo "  Radarr ES: /data/media/movies-es already configured"
          fi
        fi

        # Bookshelf: /data/media/books
        if wait_for_app_pod "bookshelf" && [ -n "$BOOKSHELF_API" ]; then
          EXISTING=$($KUBECTL exec -n ${ns} deploy/bookshelf -- \
            ${curl} -s "http://localhost:8787/api/v1/rootfolder" \
            -H "X-Api-Key: $BOOKSHELF_API" 2>/dev/null | $JQ '.[] | select(.path == "/data/media/books")' || echo "")

          if [ -z "$EXISTING" ]; then
            RESULT=$($KUBECTL exec -n ${ns} deploy/bookshelf -- \
              ${curl} -s -X POST "http://localhost:8787/api/v1/rootfolder" \
              -H "X-Api-Key: $BOOKSHELF_API" \
              -H "Content-Type: application/json" \
              -d '{"path": "/data/media/books", "name": "Books", "defaultQualityProfileId": 1, "defaultMetadataProfileId": 1}' 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "  Bookshelf: /data/media/books configured"
            else
              echo "  Bookshelf: Error - $(echo "$RESULT" | $JQ -r '.[0].errorMessage // "unknown error"')"
            fi
          else
            echo "  Bookshelf: /data/media/books already configured"
          fi
        fi

        echo ""
        echo "=== Root folders configured ==="

        create_marker "${markerFile}"
      '';
    };
  };
}
