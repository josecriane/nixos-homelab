# Jellyseerr - media requests / Jellyfin companion
# Declared via bjw-s/app-template Helm library chart. Uses the preview-OIDC
# image which adds native OIDC login support to Jellyseerr. OIDC ConfigMap
# (jellyseerr-oidc) is mounted optionally and merged into settings.json by
# the oidc-config init container. A separate systemd service
# (jellyseerr-oidc-config-setup) creates that ConfigMap once SSO is ready.
{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "media";
  domain = "${serverConfig.subdomain}.${serverConfig.domain}";
  oidcMarkerFile = "/var/lib/jellyseerr-oidc-config-done";

  release = k8s.createHelmRelease {
    name = "jellyseerr";
    namespace = ns;
    tier = "apps";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "jellyseerr";
    ingress = {
      host = "requests";
      service = "jellyseerr";
      port = 5055;
    };
  };
in
lib.recursiveUpdate release {
  systemd.services.jellyseerr-setup = {
    after = (release.systemd.services.jellyseerr-setup.after or [ ]) ++ [
      "nfs-storage-setup.service"
      "jellyfin-setup.service"
    ];
    wants = [
      "nfs-storage-setup.service"
      "jellyfin-setup.service"
    ];
  };

  systemd.services.jellyseerr-oidc-config-setup = {
    description = "Configure Jellyseerr OIDC via ConfigMap";
    after = [
      "k3s-apps.target"
      "jellyseerr-setup.service"
      "authentik-sso-setup.service"
      "jellyfin-integration-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [
      "jellyseerr-setup.service"
      "authentik-sso-setup.service"
      "jellyfin-integration-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "jellyseerr-oidc-config-setup" ''
        ${k8s.libShSource}
        setup_preamble "${oidcMarkerFile}" "Jellyseerr OIDC"

        wait_for_k3s

        if ! $KUBECTL get secret authentik-sso-credentials -n ${ns} &>/dev/null; then
          echo "No SSO credentials found, skipping OIDC configuration"
          touch ${oidcMarkerFile}
          exit 0
        fi

        JELLYSEERR_CLIENT_ID=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.JELLYSEERR_CLIENT_ID}' | base64 -d 2>/dev/null || echo "")
        JELLYSEERR_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.JELLYSEERR_CLIENT_SECRET}' | base64 -d 2>/dev/null || echo "")

        if [ -z "$JELLYSEERR_CLIENT_SECRET" ]; then
          echo "No Jellyseerr client secret in SSO credentials, skipping"
          touch ${oidcMarkerFile}
          exit 0
        fi

        echo "Creating jellyseerr-oidc ConfigMap..."

        OIDC_JSON=$(cat <<EOFJSON
        {
          "main": {"oidcLogin": true, "defaultPermissions": 2, "applicationUrl": "https://$(hostname requests)"},
          "network": {"trustProxy": true},
          "oidc": {
            "providers": [{
              "name": "authentik",
              "slug": "authentik",
              "clientId": "$JELLYSEERR_CLIENT_ID",
              "clientSecret": "$JELLYSEERR_CLIENT_SECRET",
              "issuerUrl": "https://auth.${domain}/application/o/jellyseerr/",
              "newUserLogin": true
            }]
          }
        }
        EOFJSON
        )

        $KUBECTL create configmap jellyseerr-oidc \
          --namespace=${ns} \
          --from-literal=config.json="$OIDC_JSON" \
          --dry-run=client -o yaml | $KUBECTL apply -f -

        echo "ConfigMap jellyseerr-oidc created"

        echo "Restarting Jellyseerr to apply OIDC config..."
        $KUBECTL scale deploy -n ${ns} jellyseerr --replicas=0
        for i in $(seq 1 30); do
          REMAINING=$($KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=jellyseerr --no-headers 2>/dev/null | wc -l)
          [ "$REMAINING" -eq 0 ] && break
          sleep 2
        done
        sleep 2

        $KUBECTL scale deploy -n ${ns} jellyseerr --replicas=1
        $KUBECTL rollout status deployment/jellyseerr -n ${ns} --timeout=120s 2>/dev/null || true

        JELLYSEERR_API_KEY=""
        JSEERR_SETTINGS=$(find /var/lib/rancher/k3s/storage -name "settings.json" -path "*jellyseerr*" 2>/dev/null | head -1)
        if [ -n "$JSEERR_SETTINGS" ] && [ -f "$JSEERR_SETTINGS" ]; then
          JELLYSEERR_API_KEY=$($JQ -r '.main.apiKey // empty' "$JSEERR_SETTINGS" 2>/dev/null)
        fi

        store_credentials "${ns}" "jellyseerr-credentials" \
          "API_KEY=$JELLYSEERR_API_KEY" "URL=https://$(hostname requests)"

        print_success "Jellyseerr OIDC" \
          "URL: https://$(hostname requests)" \
          "" \
          "OIDC configured via ConfigMap + init container merge"

        create_marker "${oidcMarkerFile}"
      '';
    };
  };
}
