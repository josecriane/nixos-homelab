# Jellyseerr <-> arr API key reconciliation.
#
# Each arr instance has its API key stored in a K8s Secret (<name>-api-key).
# The init-api-key init container in arr-stack/lib.nix makes the arr pod's
# config.xml always reflect the Secret. But Jellyseerr keeps its own copy of
# each arr's API key in /app/config/settings.json, configured via UI. If the
# Secret is ever rotated (or was regenerated out-of-band), Jellyseerr's copy
# goes stale and requests fail.
#
# This service reconciles Jellyseerr's settings.json with the Secrets by
# calling the Jellyseerr REST API. A timer re-runs it periodically so
# desyncs self-heal.
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
in
{
  systemd.services.jellyseerr-arr-sync = {
    description = "Reconcile Jellyseerr sonarr/radarr API keys with K8s secrets";
    after = [
      "k3s-extras.target"
      "jellyseerr-setup.service"
      "jellyseerr-oidc-config-setup.service"
      "sonarr-setup.service"
      "sonarr-es-setup.service"
      "radarr-setup.service"
      "radarr-es-setup.service"
      "arr-secrets-setup.service"
    ];
    wants = [
      "jellyseerr-setup.service"
      "jellyseerr-oidc-config-setup.service"
      "sonarr-setup.service"
      "sonarr-es-setup.service"
      "radarr-setup.service"
      "radarr-es-setup.service"
      "arr-secrets-setup.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "jellyseerr-arr-sync" ''
        ${k8s.libShSource}
        set -e

        wait_for_k3s

        if ! $KUBECTL get deploy -n ${ns} jellyseerr &>/dev/null; then
          echo "jellyseerr deployment not found; skipping"
          exit 0
        fi

        wait_for_deployment "${ns}" "jellyseerr" 300

        if ! $KUBECTL get secret jellyseerr-credentials -n ${ns} &>/dev/null; then
          echo "jellyseerr-credentials secret not found; skipping"
          exit 0
        fi

        JELLYSEERR_API_KEY=$($KUBECTL get secret jellyseerr-credentials -n ${ns} -o jsonpath='{.data.API_KEY}' | base64 -d)
        if [ -z "$JELLYSEERR_API_KEY" ]; then
          echo "jellyseerr-credentials has no API_KEY; skipping"
          exit 0
        fi

        $KUBECTL port-forward -n ${ns} svc/jellyseerr 15055:5055 >/dev/null 2>&1 &
        PF_PID=$!
        trap 'kill $PF_PID 2>/dev/null || true' EXIT

        for i in $(seq 1 20); do
          if $CURL -s -o /dev/null -w '%{http_code}' "http://localhost:15055/" 2>/dev/null | grep -qE '^(200|301|302|308)$'; then
            break
          fi
          sleep 1
        done

        JSEERR_URL="http://localhost:15055"

        sync_arr_key() {
          local arr_type=$1
          local arr_name=$2
          local arr_secret="''${arr_name}-api-key"

          if ! $KUBECTL get secret -n ${ns} "$arr_secret" &>/dev/null; then
            echo "  $arr_type/$arr_name: secret $arr_secret not found, skipping"
            return
          fi

          local api_key
          api_key=$($KUBECTL get secret -n ${ns} "$arr_secret" -o jsonpath='{.data.api-key}' | base64 -d)
          if [ -z "$api_key" ]; then
            echo "  $arr_type/$arr_name: secret has no api-key field, skipping"
            return
          fi

          local servers
          servers=$($CURL -s "$JSEERR_URL/api/v1/settings/$arr_type" \
            -H "X-Api-Key: $JELLYSEERR_API_KEY" 2>/dev/null || echo "[]")

          local server
          server=$(echo "$servers" | $JQ -c --arg name "$arr_name" '
            .[] | select(
              .hostname == $name
              or .hostname == ($name + ".media.svc.cluster.local")
              or .name == $name
            )' | head -n1)

          if [ -z "$server" ]; then
            echo "  $arr_type/$arr_name: no matching Jellyseerr server, skipping"
            return
          fi

          local server_id current_key
          server_id=$(echo "$server" | $JQ -r '.id')
          current_key=$(echo "$server" | $JQ -r '.apiKey')

          if [ "$current_key" = "$api_key" ]; then
            echo "  $arr_type/$arr_name (id=$server_id): already in sync"
            return
          fi

          local updated
          updated=$(echo "$server" | $JQ --arg key "$api_key" '.apiKey = $key | del(.id)')

          local http_code
          http_code=$(echo "$updated" | $CURL -s -o /dev/null -w '%{http_code}' \
            -X PUT "$JSEERR_URL/api/v1/settings/$arr_type/$server_id" \
            -H "X-Api-Key: $JELLYSEERR_API_KEY" \
            -H "Content-Type: application/json" \
            --data-binary @-)

          if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            echo "  $arr_type/$arr_name (id=$server_id): API key updated"
          else
            echo "  $arr_type/$arr_name (id=$server_id): PUT failed (HTTP $http_code)"
          fi
        }

        echo "Reconciling Jellyseerr arr API keys..."
        sync_arr_key sonarr sonarr
        sync_arr_key sonarr sonarr-es
        sync_arr_key radarr radarr
        sync_arr_key radarr radarr-es

        echo "Jellyseerr arr sync complete"
      '';
    };
  };

  systemd.timers.jellyseerr-arr-sync = {
    description = "Periodic Jellyseerr arr API key reconciliation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "30min";
      Unit = "jellyseerr-arr-sync.service";
    };
  };
}
