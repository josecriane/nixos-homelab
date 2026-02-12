# Recyclarr - Automatic TRaSH Guides sync for Sonarr/Radarr
# Syncs quality profiles, custom formats, and quality definitions
# Runs as a K8s CronJob every 12 hours
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
  markerFile = "/var/lib/recyclarr-setup-done";

  # Recyclarr config template with __PLACEHOLDER__ tokens for API keys
  # Substituted at runtime from K8s Secrets (avoids kubectl YAML escaping of !env_var)
  recyclarrConfigTemplate = pkgs.writeText "recyclarr-template.yml" ''
    sonarr:
      sonarr-main:
        base_url: http://sonarr:8989
        api_key: __SONARR_API_KEY__
        include:
          - template: sonarr-quality-definition-series
          - template: sonarr-v4-quality-profile-web-1080p
          - template: sonarr-v4-custom-formats-web-1080p
          - template: sonarr-v4-quality-profile-anime
          - template: sonarr-v4-custom-formats-anime
        custom_formats:
          - trash_ids:
              - 026d5aadd1a6b4e550b134cb6c72b3ca # Uncensored
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 0
          - trash_ids:
              - b2550eb333d27b75833e25b8c2557b38 # 10bit
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 10
          - trash_ids:
              - 418f50b10f1907201b6cfdf881f467b7 # Anime Dual Audio
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 0

      sonarr-es:
        base_url: http://sonarr-es:8989
        api_key: __SONARR_ES_API_KEY__
        include:
          - template: sonarr-quality-definition-series
          - template: sonarr-v4-quality-profile-web-1080p
          - template: sonarr-v4-custom-formats-web-1080p
          - template: sonarr-v4-quality-profile-anime
          - template: sonarr-v4-custom-formats-anime
        custom_formats:
          - trash_ids:
              - custom-language-not-spanish
            assign_scores_to:
              - name: WEB-1080p
                score: -10000
              - name: Remux-1080p - Anime
                score: -10000
          - trash_ids:
              - 026d5aadd1a6b4e550b134cb6c72b3ca # Uncensored
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 0
          - trash_ids:
              - b2550eb333d27b75833e25b8c2557b38 # 10bit
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 10
          - trash_ids:
              - 418f50b10f1907201b6cfdf881f467b7 # Anime Dual Audio
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 0

    radarr:
      radarr-main:
        base_url: http://radarr:7878
        api_key: __RADARR_API_KEY__
        delete_old_custom_formats: true
        include:
          - template: radarr-quality-definition-movie
          - template: radarr-quality-profile-hd-bluray-web
          - template: radarr-custom-formats-hd-bluray-web
          - template: radarr-quality-profile-anime
          - template: radarr-custom-formats-anime
        custom_formats:
          - trash_ids:
              - 064af5f084a0a24458cc8ecd3220f93f # Uncensored
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 0
          - trash_ids:
              - a5d148168c4506b55cf53984107c396e # 10bit
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 10
          - trash_ids:
              - 4a3b087eea2ce012fcc1ce319259a3be # Anime Dual Audio
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 0

      radarr-es:
        base_url: http://radarr-es:7878
        api_key: __RADARR_ES_API_KEY__
        delete_old_custom_formats: true
        include:
          - template: radarr-quality-definition-movie
          - template: radarr-quality-profile-hd-bluray-web
          - template: radarr-custom-formats-hd-bluray-web
          - template: radarr-quality-profile-anime
          - template: radarr-custom-formats-anime
        custom_formats:
          - trash_ids:
              - custom-language-not-spanish
            assign_scores_to:
              - name: HD Bluray + WEB
                score: -10000
              - name: Remux-1080p - Anime
                score: -10000
          - trash_ids:
              - 064af5f084a0a24458cc8ecd3220f93f # Uncensored
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 0
          - trash_ids:
              - a5d148168c4506b55cf53984107c396e # 10bit
            assign_scores_to:
              - name: Remux-1080p - Anime
                score: 10
          - trash_ids:
              - 4a3b087eea2ce012fcc1ce319259a3be # Anime Dual Audio
            assign_scores_to:
              - name: Remux-1080p - Anime
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
      "k3s-media.target"
      "arr-stack-setup.service"
      "arr-secrets-setup.service"
    ];
    requires = [ "k3s-media.target" ];
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
                setup_preamble "${markerFile}" "Recyclarr"

                wait_for_k3s

                # Read API keys from K8s Secrets and substitute into config template
                get_secret() {
                  $KUBECTL get secret "$1" -n ${ns} -o jsonpath='{.data.api-key}' | base64 -d
                }

                SONARR_KEY=$(get_secret sonarr-api-key)
                SONARR_ES_KEY=$(get_secret sonarr-es-api-key)
                RADARR_KEY=$(get_secret radarr-api-key)
                RADARR_ES_KEY=$(get_secret radarr-es-api-key)

                TMPDIR=$(mktemp -d)
                trap "rm -rf $TMPDIR" EXIT

                ${sed} \
                  -e "s/__SONARR_API_KEY__/$SONARR_KEY/" \
                  -e "s/__SONARR_ES_API_KEY__/$SONARR_ES_KEY/" \
                  -e "s/__RADARR_API_KEY__/$RADARR_KEY/" \
                  -e "s/__RADARR_ES_API_KEY__/$RADARR_ES_KEY/" \
                  ${recyclarrConfigTemplate} > "$TMPDIR/recyclarr.yml"

                # Create ConfigMaps from files (avoids kubectl YAML round-trip escaping)
                $KUBECTL delete configmap recyclarr-config -n ${ns} 2>/dev/null || true
                $KUBECTL create configmap recyclarr-config -n ${ns} \
                  --from-file=recyclarr.yml="$TMPDIR/recyclarr.yml"

                $KUBECTL delete configmap recyclarr-settings -n ${ns} 2>/dev/null || true
                $KUBECTL create configmap recyclarr-settings -n ${ns} \
                  --from-file=settings.yml=${recyclarrSettings}

                $KUBECTL delete configmap recyclarr-custom-formats -n ${ns} 2>/dev/null || true
                $KUBECTL create configmap recyclarr-custom-formats -n ${ns} \
                  --from-file=language-not-spanish.json=${customFormatNotSpanish}

                # Create CronJob that runs recyclarr sync every 12 hours
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: batch/v1
        kind: CronJob
        metadata:
          name: recyclarr
          namespace: ${ns}
        spec:
          schedule: "0 */12 * * *"
          successfulJobsHistoryLimit: 3
          failedJobsHistoryLimit: 3
          concurrencyPolicy: Forbid
          jobTemplate:
            spec:
              backoffLimit: 1
              template:
                spec:
                  restartPolicy: Never
                  containers:
                  - name: recyclarr
                    image: ghcr.io/recyclarr/recyclarr:7.4.0
                    command: ["recyclarr", "sync"]
                    resources:
                      requests:
                        cpu: 50m
                        memory: 64Mi
                      limits:
                        memory: 256Mi
                    volumeMounts:
                    - name: config
                      mountPath: /config/recyclarr.yml
                      subPath: recyclarr.yml
                    - name: settings
                      mountPath: /config/settings.yml
                      subPath: settings.yml
                    - name: cf-radarr
                      mountPath: /config/custom-formats/radarr/language-not-spanish.json
                      subPath: language-not-spanish.json
                    - name: cf-sonarr
                      mountPath: /config/custom-formats/sonarr/language-not-spanish.json
                      subPath: language-not-spanish.json
                  volumes:
                  - name: config
                    configMap:
                      name: recyclarr-config
                  - name: settings
                    configMap:
                      name: recyclarr-settings
                  - name: cf-radarr
                    configMap:
                      name: recyclarr-custom-formats
                  - name: cf-sonarr
                    configMap:
                      name: recyclarr-custom-formats
        EOF

                # Run initial sync immediately
                echo "Running initial Recyclarr sync..."
                $KUBECTL create job recyclarr-init --from=cronjob/recyclarr -n ${ns} 2>/dev/null || true

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

                print_success "Recyclarr" \
                  "CronJob: every 12 hours" \
                  "Sonarr: WEB-1080p + Remux-1080p Anime quality profiles" \
                  "Radarr: HD Bluray+WEB + Remux-1080p Anime quality profiles" \
                  "Manual sync: kubectl create job recyclarr-manual --from=cronjob/recyclarr -n media"

                create_marker "${markerFile}"
      '';
    };
  };
}
