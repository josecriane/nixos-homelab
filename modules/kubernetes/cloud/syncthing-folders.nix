# Syncthing folder-path reconciliation.

# This oneshot+timer reads the list of folders from Syncthing's REST API and
# PATCHes each folder whose path is outside /var/syncthing/data/ to the
# canonical path /var/syncthing/data/<folder-id>. Idempotent: folders already
# under that prefix are skipped.
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
  ns = "syncthing";
  puid = toString (serverConfig.puid or 1000);
  pgid = toString (serverConfig.pgid or 1000);
in
{
  systemd.services.syncthing-folders-reconcile = {
    description = "Reconcile Syncthing folder paths under /var/syncthing/data/";
    after = [
      "k3s-extras.target"
      "syncthing-setup.service"
    ];
    wants = [ "syncthing-setup.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "syncthing-folders-reconcile" ''
        ${k8s.libShSource}
        set -e

        wait_for_k3s

        if ! $KUBECTL get deploy -n ${ns} syncthing &>/dev/null; then
          echo "syncthing deployment not found; skipping"
          exit 0
        fi

        wait_for_deployment "${ns}" "syncthing" 300

        SYNC_API_KEY=""
        if $KUBECTL get secret syncthing-credentials -n ${ns} &>/dev/null; then
          SYNC_API_KEY=$($KUBECTL get secret syncthing-credentials -n ${ns} -o jsonpath='{.data.API_KEY}' | base64 -d)
        fi

        if [ -z "$SYNC_API_KEY" ]; then
          SYNC_API_KEY=$($KUBECTL exec -n ${ns} deploy/syncthing -- \
            sed -n 's/.*<apikey>\(.*\)<\/apikey>.*/\1/p' /var/syncthing/config/config.xml 2>/dev/null || echo "")
        fi

        if [ -z "$SYNC_API_KEY" ]; then
          echo "No Syncthing API key available; skipping"
          exit 0
        fi

        FOLDERS_JSON=$($KUBECTL exec -n ${ns} deploy/syncthing -- \
          curl -s "http://localhost:8384/rest/config/folders" \
          -H "X-API-Key: $SYNC_API_KEY" 2>/dev/null || echo "[]")

        MOVED=0
        echo "$FOLDERS_JSON" \
          | $JQ -c '.[] | select(.path | startswith("/var/syncthing/data/") | not) | {id, path}' \
          | while read -r folder; do
            folder_id=$(echo "$folder" | $JQ -r '.id')
            old_path=$(echo "$folder" | $JQ -r '.path')
            new_path="/var/syncthing/data/$folder_id"

            echo "  moving '$folder_id': '$old_path' -> '$new_path'"

            $KUBECTL exec -n ${ns} deploy/syncthing -- \
              sh -c "mkdir -p '$new_path' && touch '$new_path/.stfolder' && chown -R ${puid}:${pgid} '$new_path'"

            http_code=$($KUBECTL exec -n ${ns} deploy/syncthing -- \
              curl -s -o /dev/null -w '%{http_code}' \
              -X PATCH "http://localhost:8384/rest/config/folders/$folder_id" \
              -H "X-API-Key: $SYNC_API_KEY" \
              -H "Content-Type: application/json" \
              -d "{\"path\": \"$new_path\"}")

            if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
              echo "  '$folder_id': path updated"
            else
              echo "  '$folder_id': PATCH failed (HTTP $http_code)"
            fi
          done

        echo "Syncthing folder reconciliation complete"
      '';
    };
  };

  systemd.timers.syncthing-folders-reconcile = {
    description = "Periodic Syncthing folder path reconciliation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "8min";
      OnUnitActiveSec = "1h";
      Unit = "syncthing-folders-reconcile.service";
    };
  };
}
