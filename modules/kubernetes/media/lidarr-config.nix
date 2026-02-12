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
  markerFile = "/var/lib/lidarr-config-setup-done";
  curl = "curl";
in
{
  systemd.services.lidarr-config-setup = {
    description = "Configure Lidarr quality profiles and naming (Davo's Guide)";
    after = [
      "k3s-media.target"
      "arr-credentials-setup.service"
      "arr-root-folders-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [
      "arr-credentials-setup.service"
      "arr-root-folders-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "lidarr-config-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        MARKER_FILE="${markerFile}"
        if [ -f "$MARKER_FILE" ]; then
          echo "Lidarr config already configured"
          exit 0
        fi

        wait_for_k3s

        echo "Configuring Lidarr (Davo's Community Guide)..."

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

        LIDARR_API=$(get_secret_value ${ns} lidarr-credentials API_KEY)

        if ! wait_for_app_pod "lidarr" || [ -z "$LIDARR_API" ]; then
          echo "Lidarr not available or no API key, skipping"
          create_marker "${markerFile}"
          exit 0
        fi

        # Naming scheme
        CURRENT_NAMING=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
          ${curl} -s "http://localhost:8686/api/v1/config/naming" \
          -H "X-Api-Key: $LIDARR_API" 2>/dev/null)
        if [ -n "$CURRENT_NAMING" ]; then
          UPDATED_NAMING=$(echo "$CURRENT_NAMING" | $JQ '
            .renameTracks = true |
            .replaceIllegalCharacters = true |
            .standardTrackFormat = "{Album Title} {(Album Disambiguation)}/{Artist Name}_{Album Title}_{track:00}_{Track Title}" |
            .multiDiscTrackFormat = "{Album Title} {(Album Disambiguation)}/{Artist Name}_{Album Title}_{medium:00}-{track:00}_{Track Title}" |
            .artistFolderFormat = "{Artist Name}"
          ')
          $KUBECTL exec -n ${ns} deploy/lidarr -- \
            ${curl} -s -X PUT "http://localhost:8686/api/v1/config/naming" \
            -H "X-Api-Key: $LIDARR_API" \
            -H "Content-Type: application/json" \
            -d "$UPDATED_NAMING" >/dev/null 2>&1
          echo "  Lidarr: naming configured"
        fi

        # Media management (hardlinks)
        CURRENT_MGMT=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
          ${curl} -s "http://localhost:8686/api/v1/config/mediamanagement" \
          -H "X-Api-Key: $LIDARR_API" 2>/dev/null)
        if [ -n "$CURRENT_MGMT" ]; then
          UPDATED_MGMT=$(echo "$CURRENT_MGMT" | $JQ '.hardlinksCopy = true')
          $KUBECTL exec -n ${ns} deploy/lidarr -- \
            ${curl} -s -X PUT "http://localhost:8686/api/v1/config/mediamanagement" \
            -H "X-Api-Key: $LIDARR_API" \
            -H "Content-Type: application/json" \
            -d "$UPDATED_MGMT" >/dev/null 2>&1
          echo "  Lidarr: media management configured (hardlinks)"
        fi

        # Quality definitions - adjust FLAC and FLAC 24bit limits
        QUAL_DEFS=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
          ${curl} -s "http://localhost:8686/api/v1/qualitydefinition" \
          -H "X-Api-Key: $LIDARR_API" 2>/dev/null)
        if [ -n "$QUAL_DEFS" ]; then
          UPDATED_DEFS=$(echo "$QUAL_DEFS" | $JQ '
            [.[] |
              if .quality.name == "FLAC" then
                .minSize = 0 | .preferredSize = 895 | .maxSize = 1400
              elif .quality.name == "FLAC 24bit" then
                .minSize = 0 | .preferredSize = 895 | .maxSize = 1495
              else . end
            ]
          ')
          $KUBECTL exec -n ${ns} deploy/lidarr -- \
            ${curl} -s -X PUT "http://localhost:8686/api/v1/qualitydefinition/update" \
            -H "X-Api-Key: $LIDARR_API" \
            -H "Content-Type: application/json" \
            -d "$UPDATED_DEFS" >/dev/null 2>&1
          echo "  Lidarr: quality definitions configured (FLAC limits)"
        fi

        # Custom formats
        EXISTING_CFS=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
          ${curl} -s "http://localhost:8686/api/v1/customformat" \
          -H "X-Api-Key: $LIDARR_API" 2>/dev/null)

        create_lidarr_cf() {
          local cf_name=$1 cf_json=$2
          if echo "$EXISTING_CFS" | $JQ -e ".[] | select(.name == \"$cf_name\")" >/dev/null 2>&1; then
            echo "    CF '$cf_name' already exists"
          else
            RESULT=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
              ${curl} -s -X POST "http://localhost:8686/api/v1/customformat" \
              -H "X-Api-Key: $LIDARR_API" \
              -H "Content-Type: application/json" \
              -d "$cf_json" 2>&1)
            if echo "$RESULT" | $JQ -e '.id' >/dev/null 2>&1; then
              echo "    CF '$cf_name' created"
            else
              echo "    CF '$cf_name' error: $RESULT"
            fi
          fi
        }

        create_lidarr_cf "Preferred Groups" '{
          "name": "Preferred Groups",
          "includeCustomFormatWhenRenaming": false,
          "specifications": [
            {"name": "DeVOiD", "implementation": "ReleaseTitleSpecification", "negate": false, "required": false, "fields": {"value": "\\bDeVOiD\\b"}},
            {"name": "PERFECT", "implementation": "ReleaseTitleSpecification", "negate": false, "required": false, "fields": {"value": "\\bPERFECT\\b"}},
            {"name": "ENRiCH", "implementation": "ReleaseTitleSpecification", "negate": false, "required": false, "fields": {"value": "\\bENRiCH\\b"}}
          ]
        }'

        create_lidarr_cf "CD" '{
          "name": "CD",
          "includeCustomFormatWhenRenaming": false,
          "specifications": [
            {"name": "CD", "implementation": "ReleaseTitleSpecification", "negate": false, "required": false, "fields": {"value": "\\bCD\\b"}}
          ]
        }'

        create_lidarr_cf "WEB" '{
          "name": "WEB",
          "includeCustomFormatWhenRenaming": false,
          "specifications": [
            {"name": "WEB", "implementation": "ReleaseTitleSpecification", "negate": false, "required": false, "fields": {"value": "\\bWEB\\b"}}
          ]
        }'

        create_lidarr_cf "Lossless" '{
          "name": "Lossless",
          "includeCustomFormatWhenRenaming": false,
          "specifications": [
            {"name": "FLAC", "implementation": "ReleaseTitleSpecification", "negate": false, "required": false, "fields": {"value": "\\bFLAC\\b"}}
          ]
        }'

        create_lidarr_cf "Vinyl" '{
          "name": "Vinyl",
          "includeCustomFormatWhenRenaming": false,
          "specifications": [
            {"name": "Vinyl", "implementation": "ReleaseTitleSpecification", "negate": false, "required": false, "fields": {"value": "\\bVinyl\\b"}}
          ]
        }'

        echo "  Lidarr: custom formats configured"

        # Quality profile - get all CFs, find the first profile, update it
        ALL_CFS=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
          ${curl} -s "http://localhost:8686/api/v1/customformat" \
          -H "X-Api-Key: $LIDARR_API" 2>/dev/null)
        PROFILES=$($KUBECTL exec -n ${ns} deploy/lidarr -- \
          ${curl} -s "http://localhost:8686/api/v1/qualityprofile" \
          -H "X-Api-Key: $LIDARR_API" 2>/dev/null)

        if [ -n "$PROFILES" ] && [ -n "$ALL_CFS" ]; then
          PROFILE_ID=$(echo "$PROFILES" | $JQ '.[0].id')

          if [ -n "$PROFILE_ID" ] && [ "$PROFILE_ID" != "null" ]; then
            CURRENT_PROFILE=$(echo "$PROFILES" | $JQ ".[0]")

            CF_PREFERRED_ID=$(echo "$ALL_CFS" | $JQ '[.[] | select(.name == "Preferred Groups")][0].id // empty')
            CF_CD_ID=$(echo "$ALL_CFS" | $JQ '[.[] | select(.name == "CD")][0].id // empty')
            CF_WEB_ID=$(echo "$ALL_CFS" | $JQ '[.[] | select(.name == "WEB")][0].id // empty')
            CF_LOSSLESS_ID=$(echo "$ALL_CFS" | $JQ '[.[] | select(.name == "Lossless")][0].id // empty')
            CF_VINYL_ID=$(echo "$ALL_CFS" | $JQ '[.[] | select(.name == "Vinyl")][0].id // empty')

            UPDATED_PROFILE=$(echo "$CURRENT_PROFILE" | $JQ \
              --argjson pref_id "''${CF_PREFERRED_ID:-0}" \
              --argjson cd_id "''${CF_CD_ID:-0}" \
              --argjson web_id "''${CF_WEB_ID:-0}" \
              --argjson lossless_id "''${CF_LOSSLESS_ID:-0}" \
              --argjson vinyl_id "''${CF_VINYL_ID:-0}" '
              .upgradeAllowed = true |
              .minFormatScore = 1 |
              .formatItems = [
                (if $pref_id > 0 then {format: $pref_id, name: "Preferred Groups", score: 10} else empty end),
                (if $cd_id > 0 then {format: $cd_id, name: "CD", score: 5} else empty end),
                (if $web_id > 0 then {format: $web_id, name: "WEB", score: 3} else empty end),
                (if $lossless_id > 0 then {format: $lossless_id, name: "Lossless", score: 5} else empty end),
                (if $vinyl_id > 0 then {format: $vinyl_id, name: "Vinyl", score: -10} else empty end)
              ]
            ')

            $KUBECTL exec -n ${ns} deploy/lidarr -- \
              ${curl} -s -X PUT "http://localhost:8686/api/v1/qualityprofile/$PROFILE_ID" \
              -H "X-Api-Key: $LIDARR_API" \
              -H "Content-Type: application/json" \
              -d "$UPDATED_PROFILE" >/dev/null 2>&1
            echo "  Lidarr: quality profile updated (upgrades, CF scores, min score: 1)"
          fi
        fi

        echo ""
        echo "=== Lidarr configuration complete ==="

        create_marker "${markerFile}"
      '';
    };
  };
}
