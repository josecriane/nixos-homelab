# Recyclarr - Automatic TRaSH Guides sync for Sonarr/Radarr
# Syncs quality profiles, custom formats, and quality definitions
# Runs as a K8s CronJob every 12 hours.
#
# Config is generated dynamically at setup time: only arr deployments with
# ready replicas are included (paused services are skipped), and api-keys are
# read live from each pod's /config/config.xml so recyclarr never drifts from
# what the running app actually uses.
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

  # Per-instance recyclarr config fragments.
  # Each one is the YAML block nested under `sonarr:` or `radarr:` for that
  # instance. `__API_KEY__` is replaced at runtime with the pod's live key.
  sonarrMainFragment = pkgs.writeText "recyclarr-sonarr-main.yml" ''
    sonarr-main:
      base_url: http://sonarr:8989
      api_key: __API_KEY__
      quality_definition:
        type: series
      quality_profiles:
        - trash_id: 72dae194fc92bf828f32cde7744e51a1 # WEB-1080p
          reset_unmatched_scores:
            enabled: true
        - trash_id: 20e0fc959f1f1704bed501f23bdae76f # Anime Remux-1080p
          reset_unmatched_scores:
            enabled: true
      custom_formats:
        - trash_ids:
            - 026d5aadd1a6b4e550b134cb6c72b3ca # Uncensored
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 0
        - trash_ids:
            - b2550eb333d27b75833e25b8c2557b38 # 10bit
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 10
        - trash_ids:
            - 418f50b10f1907201b6cfdf881f467b7 # Anime Dual Audio
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 0
  '';

  sonarrEsFragment = pkgs.writeText "recyclarr-sonarr-es.yml" ''
    sonarr-es:
      base_url: http://sonarr-es:8989
      api_key: __API_KEY__
      quality_definition:
        type: series
      quality_profiles:
        - trash_id: 72dae194fc92bf828f32cde7744e51a1 # WEB-1080p
          reset_unmatched_scores:
            enabled: true
        - trash_id: 20e0fc959f1f1704bed501f23bdae76f # Anime Remux-1080p
          reset_unmatched_scores:
            enabled: true
      custom_formats:
        - trash_ids:
            - custom-language-not-spanish
          assign_scores_to:
            - name: WEB-1080p
              score: -10000
            - name: "[Anime] Remux-1080p"
              score: -10000
        - trash_ids:
            - 026d5aadd1a6b4e550b134cb6c72b3ca # Uncensored
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 0
        - trash_ids:
            - b2550eb333d27b75833e25b8c2557b38 # 10bit
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 10
        - trash_ids:
            - 418f50b10f1907201b6cfdf881f467b7 # Anime Dual Audio
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 0
  '';

  radarrMainFragment = pkgs.writeText "recyclarr-radarr-main.yml" ''
    radarr-main:
      base_url: http://radarr:7878
      api_key: __API_KEY__
      quality_definition:
        type: movie
      quality_profiles:
        - trash_id: d1d67249d3890e49bc12e275d989a7e9 # HD Bluray + WEB
          reset_unmatched_scores:
            enabled: true
        - trash_id: 722b624f9af1e492284c4bc842153a38 # Anime
          reset_unmatched_scores:
            enabled: true
      custom_formats:
        - trash_ids:
            - 064af5f084a0a24458cc8ecd3220f93f # Uncensored
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 0
        - trash_ids:
            - a5d148168c4506b55cf53984107c396e # 10bit
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 10
        - trash_ids:
            - 4a3b087eea2ce012fcc1ce319259a3be # Anime Dual Audio
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 0
  '';

  radarrEsFragment = pkgs.writeText "recyclarr-radarr-es.yml" ''
    radarr-es:
      base_url: http://radarr-es:7878
      api_key: __API_KEY__
      quality_definition:
        type: movie
      quality_profiles:
        - trash_id: d1d67249d3890e49bc12e275d989a7e9 # HD Bluray + WEB
          reset_unmatched_scores:
            enabled: true
        - trash_id: 722b624f9af1e492284c4bc842153a38 # Anime
          reset_unmatched_scores:
            enabled: true
      custom_formats:
        - trash_ids:
            - custom-language-not-spanish
          assign_scores_to:
            - name: HD Bluray + WEB
              score: -10000
            - name: "[Anime] Remux-1080p"
              score: -10000
        - trash_ids:
            - 064af5f084a0a24458cc8ecd3220f93f # Uncensored
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 0
        - trash_ids:
            - a5d148168c4506b55cf53984107c396e # 10bit
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 10
        - trash_ids:
            - 4a3b087eea2ce012fcc1ce319259a3be # Anime Dual Audio
          assign_scores_to:
            - name: "[Anime] Remux-1080p"
              score: 0
  '';

  recyclarrSettings = pkgs.writeText "recyclarr-settings.yml" ''
    resource_providers:
      - name: custom-radarr
        type: custom-formats
        service: radarr
        path: /config/custom-formats/radarr
      - name: custom-sonarr
        type: custom-formats
        service: sonarr
        path: /config/custom-formats/sonarr
  '';

  customFormatNotSpanish = pkgs.writeText "language-not-spanish.json" (
    builtins.toJSON {
      trash_id = "custom-language-not-spanish";
      trash_scores = {
        default = -10000;
      };
      name = "Language: Not Spanish";
      includeCustomFormatWhenRenaming = false;
      specifications = [
        {
          name = "Not Spanish Language";
          implementation = "LanguageSpecification";
          negate = true;
          required = false;
          fields = {
            value = 3;
          };
        }
      ];
    }
  );

  sed = "${pkgs.gnused}/bin/sed";
in
{
  systemd.services.recyclarr-setup = {
    description = "Setup Recyclarr TRaSH Guides sync";
    after = [
      "k3s-apps.target"
      "arr-stack-setup.service"
      "arr-secrets-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [
      "arr-stack-setup.service"
      "arr-secrets-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "recyclarr-setup" ''
        ${k8s.libShSource}
        set -e
        # No marker: runs on every deploy so the configmap tracks any drift
        # in pod api-keys or pause state.
        echo "Installing Recyclarr..."

        wait_for_k3s

        TMPDIR=$(mktemp -d)
        trap "rm -rf $TMPDIR" EXIT

        # Read live api-key from the running pod's config.xml. This avoids any
        # drift between the K8s secret and the key the app actually uses.
        # Returns empty if the deployment has no ready replicas.
        get_live_api_key() {
          local svc=$1
          local ready
          ready=$($KUBECTL get deploy -n ${ns} "$svc" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
          [ "''${ready:-0}" -ge 1 ] || return 1
          $KUBECTL exec -n ${ns} "deploy/$svc" -c main -- \
            sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' /config/config.xml 2>/dev/null
        }

        # Append a per-instance fragment to $out_file with api-key substituted.
        # Fragments are stored un-nested (column 0). We prefix every non-empty
        # line with 2 spaces so the instance becomes a child of `sonarr:` /
        # `radarr:` when concatenated below.
        # Returns 0 on append, 1 if the deployment is not ready.
        emit_fragment() {
          local svc=$1 fragment=$2 out_file=$3 key
          if key=$(get_live_api_key "$svc") && [ -n "$key" ]; then
            ${sed} -e "s/__API_KEY__/$key/" -e 's/^\(.\)/  \1/' "$fragment" >> "$out_file"
            echo "  Included: $svc"
            return 0
          fi
          echo "  Skipped (not ready): $svc"
          return 1
        }

        echo "Building recyclarr config from ready arr deployments..."
        SONARR_BODY=$(mktemp)
        RADARR_BODY=$(mktemp)
        trap "rm -rf $TMPDIR $SONARR_BODY $RADARR_BODY" EXIT

        HAVE_SONARR=""
        emit_fragment sonarr    "${sonarrMainFragment}" "$SONARR_BODY" && HAVE_SONARR=1 || true
        emit_fragment sonarr-es "${sonarrEsFragment}"   "$SONARR_BODY" && HAVE_SONARR=1 || true

        HAVE_RADARR=""
        emit_fragment radarr    "${radarrMainFragment}" "$RADARR_BODY" && HAVE_RADARR=1 || true
        emit_fragment radarr-es "${radarrEsFragment}"   "$RADARR_BODY" && HAVE_RADARR=1 || true

        > "$TMPDIR/recyclarr.yml"
        if [ -n "$HAVE_SONARR" ]; then
          echo "sonarr:" >> "$TMPDIR/recyclarr.yml"
          cat "$SONARR_BODY" >> "$TMPDIR/recyclarr.yml"
        fi
        if [ -n "$HAVE_RADARR" ]; then
          echo "radarr:" >> "$TMPDIR/recyclarr.yml"
          cat "$RADARR_BODY" >> "$TMPDIR/recyclarr.yml"
        fi

        if [ ! -s "$TMPDIR/recyclarr.yml" ]; then
          echo "No ready arr deployments; leaving recyclarr config untouched."
          exit 0
        fi

        $KUBECTL create configmap recyclarr-config -n ${ns} \
          --from-file=recyclarr.yml="$TMPDIR/recyclarr.yml" \
          --dry-run=client -o yaml | $KUBECTL apply -f -

        $KUBECTL create configmap recyclarr-settings -n ${ns} \
          --from-file=settings.yml=${recyclarrSettings} \
          --dry-run=client -o yaml | $KUBECTL apply -f -

        $KUBECTL create configmap recyclarr-custom-formats -n ${ns} \
          --from-file=language-not-spanish.json=${customFormatNotSpanish} \
          --dry-run=client -o yaml | $KUBECTL apply -f -

        # Create CronJob that runs recyclarr sync every 12 hours
        ${k8s.applyManifestsScript {
          name = "recyclarr-cronjob";
          manifests = [ ./recyclarr-cronjob.yaml ];
          substitutions = {
            NAMESPACE = ns;
          };
        }}

        # Run initial sync immediately
        echo "Running initial Recyclarr sync..."
        $KUBECTL delete job recyclarr-init -n ${ns} --ignore-not-found
        $KUBECTL create job recyclarr-init --from=cronjob/recyclarr -n ${ns}

        # Wait for the initial job to complete (max 5 min)
        for i in $(seq 1 30); do
          STATUS=$($KUBECTL get job recyclarr-init -n ${ns} -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")
          if [ "$STATUS" = "Complete" ] || [ "$STATUS" = "SuccessCriteriaMet" ]; then
            echo "Initial sync completed"
            break
          elif [ "$STATUS" = "Failed" ]; then
            echo "WARN: Initial sync failed, will retry on next schedule"
            $KUBECTL logs job/recyclarr-init -n ${ns} 2>/dev/null | tail -20
            break
          fi
          echo "Waiting for initial sync... ($i/30)"
          sleep 10
        done

        # Set language to "Spanish" on ES quality profiles so they accept
        # Spanish releases (profile-level "Original" language would reject them).
        # Only runs for services that are ready.
        set_es_language() {
          local svc=$1 port=$2 key
          if ! key=$(get_live_api_key "$svc") || [ -z "$key" ]; then
            echo "  Skipped language update (not ready): $svc"
            return 0
          fi
          echo "  Setting Spanish language on $svc quality profiles..."
          for PROFILE_ID in $($KUBECTL exec -n ${ns} "deploy/$svc" -c main -- \
              curl -s "http://localhost:$port/api/v3/qualityprofile" -H "X-Api-Key: $key" 2>/dev/null | $JQ '.[].id'); do
            $KUBECTL exec -n ${ns} "deploy/$svc" -c main -- \
              curl -s "http://localhost:$port/api/v3/qualityprofile/$PROFILE_ID" -H "X-Api-Key: $key" 2>/dev/null | \
              $JQ '.language = {"id": 3, "name": "Spanish"}' | \
              $KUBECTL exec -i -n ${ns} "deploy/$svc" -c main -- \
                curl -s -o /dev/null -X PUT "http://localhost:$port/api/v3/qualityprofile/$PROFILE_ID" \
                  -H "X-Api-Key: $key" -H "Content-Type: application/json" -d @- 2>/dev/null
          done
        }
        set_es_language radarr-es 7878
        set_es_language sonarr-es 8989

        print_success "Recyclarr" \
          "CronJob: every 12 hours" \
          "Sonarr: WEB-1080p + Remux-1080p Anime quality profiles" \
          "Radarr: HD Bluray+WEB + Remux-1080p Anime quality profiles" \
          "Manual sync: kubectl create job recyclarr-manual --from=cronjob/recyclarr -n media"
      '';
    };
  };
}
