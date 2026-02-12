{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/bazarr-config-setup-done";
  curl = "curl";
  opensubtitlesUsername = serverConfig.opensubtitles.username or "";
in
{
  age.secrets.opensubtitles-password = lib.mkIf (opensubtitlesUsername != "") {
    file = "${secretsPath}/opensubtitles-password.age";
  };

  systemd.services.bazarr-config-setup = {
    description = "Configure Bazarr subtitle providers and connections";
    after = [
      "k3s-media.target"
      "arr-credentials-setup.service"
      "bazarr-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [
      "arr-credentials-setup.service"
      "bazarr-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "bazarr-config-setup" ''
                ${k8s.libShSource}
                export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                set +e

                MARKER_FILE="${markerFile}"
                if [ -f "$MARKER_FILE" ]; then
                  echo "Bazarr config already configured"
                  exit 0
                fi

                wait_for_k3s

                echo "Configuring Bazarr (subtitles)..."

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
                RADARR_API=$(get_secret_value ${ns} radarr-credentials API_KEY)
                BAZARR_API=$(get_secret_value ${ns} bazarr-credentials API_KEY)
                # Fallback: read Bazarr API key from auth section of config
                if [ -z "$BAZARR_API" ]; then
                  BAZARR_API=$($KUBECTL exec -n ${ns} deploy/bazarr -- \
                    sh -c "sed -n '/^auth:/,/^[a-z]/p' /config/config/config.yaml 2>/dev/null | grep 'apikey:' | head -1 | sed 's/.*apikey: *//' | tr -d ' '" 2>/dev/null || echo "")
                fi

                if [ -z "$SONARR_API" ] || [ -z "$RADARR_API" ]; then
                  echo "ERROR: Required credentials not found"
                  exit 1
                fi

                if ! wait_for_app_pod "bazarr"; then
                  echo "Bazarr not available, skipping"
                  exit 1
                fi

                # Check if already configured by verifying Sonarr apikey is set
                BAZARR_SONARR_KEY=$($KUBECTL exec -n ${ns} deploy/bazarr -- \
                  sh -c "sed -n '/^sonarr:/,/^[a-z]/p' /config/config/config.yaml | grep 'apikey:' | head -1 | sed \"s/.*apikey: *//\" | tr -d \" '\"" 2>/dev/null || echo "")

                # Ensure all providers are enabled (always, even if Bazarr is already configured)
                echo "  Ensuring subtitle providers are enabled..."
                BAZARR_PROVIDERS_TMP=$(mktemp)
                cat > "$BAZARR_PROVIDERS_TMP" << 'PROVEOF'
        #!/bin/sh
        CFG=/config/config/config.yaml
        [ ! -f "$CFG" ] && echo "SKIP" && exit 0
        for provider in yifysubtitles subtitulamostv; do
          if ! grep -q "^  - $provider" "$CFG"; then
            sed -i "/^  enabled_providers:/a\\  - $provider" "$CFG"
            echo "ADDED $provider"
          fi
        done
        echo "OK"
        PROVEOF
                BAZARR_POD=$($KUBECTL get pods -n ${ns} -l app=bazarr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                if [ -n "$BAZARR_POD" ]; then
                  $KUBECTL cp "$BAZARR_PROVIDERS_TMP" ${ns}/$BAZARR_POD:/tmp/bazarr-providers.sh
                  PROV_RESULT=$($KUBECTL exec -n ${ns} $BAZARR_POD -- sh /tmp/bazarr-providers.sh 2>&1)
                  rm -f "$BAZARR_PROVIDERS_TMP"
                  if echo "$PROV_RESULT" | grep -q "ADDED"; then
                    echo "  Providers updated, restarting Bazarr..."
                    $KUBECTL rollout restart deployment/bazarr -n ${ns}
                    $KUBECTL rollout status deployment/bazarr -n ${ns} --timeout=120s 2>/dev/null || true
                  fi
                  echo "  Providers: opensubtitlescom, subdivx, podnapisi, yifysubtitles, subtitulamostv"
                fi

                # Configure OpenSubtitles.com credentials (always, even if Bazarr is already configured)
                ${lib.optionalString (opensubtitlesUsername != "") ''
                            echo "  Configuring OpenSubtitles.com credentials..."
                            OPENSUB_PASS=""
                            if [ -f "${config.age.secrets.opensubtitles-password.path}" ]; then
                              OPENSUB_PASS=$(cat "${config.age.secrets.opensubtitles-password.path}")
                            fi
                            BAZARR_OPENSUB_TMP=$(mktemp)
                            cat > "$BAZARR_OPENSUB_TMP" << 'OSUBEOF'
                  #!/bin/sh
                  CFG=/config/config/config.yaml
                  [ ! -f "$CFG" ] && echo "FAIL: config not found" && exit 1
                  sed -i '/^opensubtitlescom:/,/^[a-z]/{
                    s/^  username: .*/  username: OPENSUBTITLES_USER/
                    s/^  password: .*/  password: OPENSUBTITLES_PASS/
                  }' "$CFG"
                  echo "OK"
                  OSUBEOF
                            sed -i "s|OPENSUBTITLES_USER|${opensubtitlesUsername}|g" "$BAZARR_OPENSUB_TMP"
                            sed -i "s|OPENSUBTITLES_PASS|$OPENSUB_PASS|g" "$BAZARR_OPENSUB_TMP"
                            BAZARR_POD=$($KUBECTL get pods -n ${ns} -l app=bazarr -o jsonpath='{.items[0].metadata.name}')
                            $KUBECTL cp "$BAZARR_OPENSUB_TMP" ${ns}/$BAZARR_POD:/tmp/bazarr-opensub.sh
                            OSUB_RESULT=$($KUBECTL exec -n ${ns} $BAZARR_POD -- sh /tmp/bazarr-opensub.sh 2>&1)
                            rm -f "$BAZARR_OPENSUB_TMP"
                            if echo "$OSUB_RESULT" | grep -q "OK"; then
                              echo "  OpenSubtitles.com: credentials configured"
                              $KUBECTL rollout restart deployment/bazarr -n ${ns}
                              $KUBECTL rollout status deployment/bazarr -n ${ns} --timeout=120s 2>/dev/null || true
                            else
                              echo "  OpenSubtitles.com: Error - $OSUB_RESULT"
                            fi
                ''}

                if [ -n "$BAZARR_SONARR_KEY" ]; then
                  echo "  Bazarr: already configured"
                else
                  # Bazarr API doesn't persist changes reliably, modify config.yaml directly
                  BAZARR_SETUP_TMP=$(mktemp)
                  cat > "$BAZARR_SETUP_TMP" << 'BAZEOF'
        #!/bin/sh
        CFG=/config/config/config.yaml
        [ ! -f "$CFG" ] && echo "FAIL: config not found" && exit 1

        # Enable Sonarr and Radarr
        sed -i 's/^  use_sonarr: false/  use_sonarr: true/' "$CFG"
        sed -i 's/^  use_radarr: false/  use_radarr: true/' "$CFG"

        # Fix enabled_providers - replace inline [] or existing list with proper YAML list
        sed -i '/^  enabled_providers:/,/^  [a-z]/{/^  enabled_providers:/d;/^  - /d;}' "$CFG"
        sed -i '/^general:/a\  enabled_providers:\n  - opensubtitlescom\n  - subdivx\n  - podnapisi\n  - yifysubtitles\n  - subtitulamostv' "$CFG"

        # Configure Sonarr connection
        sed -i '/^sonarr:/,/^[a-z]/{
          s/^  ip: .*/  ip: SONARR_HOST/
          s/^  port: .*/  port: 8989/
          s/^  apikey: .*/  apikey: SONARR_KEY/
          s/^  base_url: .*/  base_url: \//
          s/^  ssl: .*/  ssl: false/
        }' "$CFG"

        # Configure Radarr connection
        sed -i '/^radarr:/,/^[a-z]/{
          s/^  ip: .*/  ip: RADARR_HOST/
          s/^  port: .*/  port: 7878/
          s/^  apikey: .*/  apikey: RADARR_KEY/
          s/^  base_url: .*/  base_url: \//
          s/^  ssl: .*/  ssl: false/
        }' "$CFG"

        echo "OK"
        BAZEOF
                  # Replace placeholders with actual values
                  sed -i "s|SONARR_HOST|sonarr.media.svc.cluster.local|g" "$BAZARR_SETUP_TMP"
                  sed -i "s|SONARR_KEY|$SONARR_API|g" "$BAZARR_SETUP_TMP"
                  sed -i "s|RADARR_HOST|radarr.media.svc.cluster.local|g" "$BAZARR_SETUP_TMP"
                  sed -i "s|RADARR_KEY|$RADARR_API|g" "$BAZARR_SETUP_TMP"

                  BAZARR_POD=$($KUBECTL get pods -n ${ns} -l app=bazarr -o jsonpath='{.items[0].metadata.name}')
                  $KUBECTL cp "$BAZARR_SETUP_TMP" ${ns}/$BAZARR_POD:/tmp/bazarr-setup.sh
                  BAZARR_RESULT=$($KUBECTL exec -n ${ns} $BAZARR_POD -- sh /tmp/bazarr-setup.sh 2>&1)
                  rm -f "$BAZARR_SETUP_TMP"

                  if echo "$BAZARR_RESULT" | grep -q "OK"; then
                    # Restart to apply config changes
                    $KUBECTL rollout restart deployment/bazarr -n ${ns}
                    $KUBECTL rollout status deployment/bazarr -n ${ns} --timeout=120s 2>/dev/null || true
                    sleep 10

                    # Configure languages and profile via DB (Bazarr API is read-only for these)
                    $KUBECTL scale deploy -n ${ns} bazarr --replicas=0 2>/dev/null
                    for i in $(seq 1 30); do
                      REMAINING=$($KUBECTL get pods -n ${ns} -l app=bazarr --no-headers 2>/dev/null | wc -l)
                      [ "$REMAINING" -eq 0 ] && break
                      sleep 2
                    done
                    sleep 2

                    BAZARR_DB=$(find /var/lib/rancher/k3s/storage -name "bazarr.db" -path "*bazarr*" 2>/dev/null | head -1)
                    if [ -n "$BAZARR_DB" ] && [ -f "$BAZARR_DB" ]; then
                      # Enable Spanish and English languages
                      ${pkgs.sqlite}/bin/sqlite3 "$BAZARR_DB" "UPDATE table_settings_languages SET enabled=1 WHERE code3 IN ('eng','spa');"

                      # Create language profile if it doesn't exist
                      PROFILE_COUNT=$(${pkgs.sqlite}/bin/sqlite3 "$BAZARR_DB" "SELECT COUNT(*) FROM table_languages_profiles WHERE name='Spanish + English';")
                      if [ "$PROFILE_COUNT" -eq 0 ]; then
                        ${pkgs.sqlite}/bin/sqlite3 "$BAZARR_DB" "INSERT INTO table_languages_profiles (profileId, cutoff, originalFormat, items, name) VALUES (1, NULL, NULL, '[{\"id\": 1, \"language\": \"es\", \"hi\": \"False\", \"forced\": \"False\", \"audio_exclude\": \"False\"}, {\"id\": 2, \"language\": \"en\", \"hi\": \"False\", \"forced\": \"False\", \"audio_exclude\": \"False\"}]', 'Spanish + English');"
                        echo "    Language profile created: Spanish + English"
                      fi

                      # Set as default profile for series and movies in config.yaml
                      BAZARR_CFG=$(find /var/lib/rancher/k3s/storage -name "config.yaml" -path "*bazarr*" 2>/dev/null | head -1)
                      if [ -n "$BAZARR_CFG" ]; then
                        ${pkgs.gnused}/bin/sed -i 's/serie_default_enabled: false/serie_default_enabled: true/; s/serie_default_profile: .*/serie_default_profile: "1"/; s/movie_default_enabled: false/movie_default_enabled: true/; s/movie_default_profile: .*/movie_default_profile: "1"/' "$BAZARR_CFG"
                        # TRaSH Guides subtitle scoring thresholds
                        ${pkgs.gnused}/bin/sed -i 's/minimum_score_movie: .*/minimum_score_movie: 80/; s/minimum_score: .*/minimum_score: 90/; s/use_hash: .*/use_hash: true/' "$BAZARR_CFG"
                        echo "    Default profile and TRaSH scoring configured"
                      fi
                    else
                      echo "    WARN: bazarr.db not found"
                    fi

                    # Scale back up
                    $KUBECTL scale deploy -n ${ns} bazarr --replicas=1 2>/dev/null
                    $KUBECTL rollout status deployment/bazarr -n ${ns} --timeout=120s 2>/dev/null || true

                    echo "  Bazarr: configured"
                    echo "    Providers: OpenSubtitles.com, Subdivx, Podnapisi, YIFY Subtitles, Subtitulamos"
                    echo "    Connected: Sonarr + Radarr"
                    echo "    Languages: Spanish + English (default profile)"
                  else
                    echo "  Bazarr: Error - $BAZARR_RESULT"
                  fi
                fi

                echo ""
                echo "=== Bazarr configuration complete ==="

                create_marker "${markerFile}"
      '';
    };
  };
}
