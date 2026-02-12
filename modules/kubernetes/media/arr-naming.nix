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
  markerFile = "/var/lib/arr-naming-setup-done";
  curl = "curl";
in
{
  systemd.services.arr-naming-setup = {
    description = "Configure TRaSH Guides naming and media management for Sonarr/Radarr";
    after = [
      "k3s-media.target"
      "arr-credentials-setup.service"
      "recyclarr-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [
      "arr-credentials-setup.service"
      "recyclarr-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "arr-naming-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        MARKER_FILE="${markerFile}"
        if [ -f "$MARKER_FILE" ]; then
          echo "Naming and media management already configured"
          exit 0
        fi

        wait_for_k3s

        echo "Configuring naming and media management (TRaSH Guides)..."

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

        if [ -z "$SONARR_API" ] || [ -z "$RADARR_API" ]; then
          echo "ERROR: Required credentials not found"
          exit 1
        fi

        configure_sonarr_settings() {
          local api_key=$1 port=$2 deploy=$3 label=$4

          if ! wait_for_app_pod "$deploy"; then return; fi

          NAMING=$($KUBECTL exec -n ${ns} deploy/$deploy -- \
            ${curl} -s "http://localhost:$port/api/v3/config/naming" \
            -H "X-Api-Key: $api_key" 2>/dev/null)

          if [ -n "$NAMING" ]; then
            UPDATED=$(echo "$NAMING" | $JQ '
              .renameEpisodes = true |
              .standardEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Custom Formats}][{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}" |
              .dailyEpisodeFormat = "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Custom Formats}][{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}" |
              .animeEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Custom Formats}][{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoCodec} {MediaInfo VideoBitDepth}bit]{-Release Group}" |
              .seriesFolderFormat = "{Series TitleYear}" |
              .seasonFolderFormat = "Season {season:00}"
            ')
            $KUBECTL exec -n ${ns} deploy/$deploy -- \
              ${curl} -s -X PUT "http://localhost:$port/api/v3/config/naming" \
              -H "X-Api-Key: $api_key" \
              -H "Content-Type: application/json" \
              -d "$UPDATED" >/dev/null 2>&1
            echo "  $label: naming configured"
          fi

          MGMT=$($KUBECTL exec -n ${ns} deploy/$deploy -- \
            ${curl} -s "http://localhost:$port/api/v3/config/mediamanagement" \
            -H "X-Api-Key: $api_key" 2>/dev/null)

          if [ -n "$MGMT" ]; then
            UPDATED=$(echo "$MGMT" | $JQ '
              .autoRenameFolders = true |
              .importExtraFiles = true |
              .extraFileExtensions = "srt,sub,idx" |
              .hardlinksCopy = true |
              .autoUnmonitorPreviouslyDownloadedEpisodes = true |
              .downloadPropersAndRepacks = "doNotPrefer"
            ')
            $KUBECTL exec -n ${ns} deploy/$deploy -- \
              ${curl} -s -X PUT "http://localhost:$port/api/v3/config/mediamanagement" \
              -H "X-Api-Key: $api_key" \
              -H "Content-Type: application/json" \
              -d "$UPDATED" >/dev/null 2>&1
            echo "  $label: media management configured (hardlinks, rename, extras)"
          fi
        }

        configure_radarr_settings() {
          local api_key=$1 port=$2 deploy=$3 label=$4

          if ! wait_for_app_pod "$deploy"; then return; fi

          NAMING=$($KUBECTL exec -n ${ns} deploy/$deploy -- \
            ${curl} -s "http://localhost:$port/api/v3/config/naming" \
            -H "X-Api-Key: $api_key" 2>/dev/null)

          if [ -n "$NAMING" ]; then
            UPDATED=$(echo "$NAMING" | $JQ '
              .renameMovies = true |
              .movieFolderFormat = "{Movie CleanTitle} ({Release Year})" |
              .standardMovieFormat = "{Movie CleanTitle} {(Release Year)} {Edition Tags} [{Custom Formats}][{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}"
            ')
            $KUBECTL exec -n ${ns} deploy/$deploy -- \
              ${curl} -s -X PUT "http://localhost:$port/api/v3/config/naming" \
              -H "X-Api-Key: $api_key" \
              -H "Content-Type: application/json" \
              -d "$UPDATED" >/dev/null 2>&1
            echo "  $label: naming configured"
          fi

          MGMT=$($KUBECTL exec -n ${ns} deploy/$deploy -- \
            ${curl} -s "http://localhost:$port/api/v3/config/mediamanagement" \
            -H "X-Api-Key: $api_key" 2>/dev/null)

          if [ -n "$MGMT" ]; then
            UPDATED=$(echo "$MGMT" | $JQ '
              .autoRenameFolders = true |
              .importExtraFiles = true |
              .extraFileExtensions = "srt,sub,idx" |
              .hardlinksCopy = true |
              .minimumFreeSpaceWhenImporting = 10000 |
              .downloadPropersAndRepacks = "doNotPrefer"
            ')
            $KUBECTL exec -n ${ns} deploy/$deploy -- \
              ${curl} -s -X PUT "http://localhost:$port/api/v3/config/mediamanagement" \
              -H "X-Api-Key: $api_key" \
              -H "Content-Type: application/json" \
              -d "$UPDATED" >/dev/null 2>&1
            echo "  $label: media management configured (hardlinks, rename, extras)"
          fi
        }

        configure_sonarr_settings "$SONARR_API" 8989 sonarr "Sonarr"
        configure_sonarr_settings "$SONARR_ES_API" 8989 sonarr-es "Sonarr ES"
        configure_radarr_settings "$RADARR_API" 7878 radarr "Radarr"
        configure_radarr_settings "$RADARR_ES_API" 7878 radarr-es "Radarr ES"

        echo ""
        echo "=== Naming and media management configured ==="

        create_marker "${markerFile}"
      '';
    };
  };
}
