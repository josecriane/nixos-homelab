{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "monitoring";
  markerFile = "/var/lib/monitoring-setup-done";
in
{
  systemd.services.monitoring-setup = {
    description = "Setup Prometheus and Grafana monitoring stack";
    after = [ "k3s-storage.target" ];
    requires = [ "k3s-storage.target" ];
    # TIER 3: Core
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "monitoring-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Monitoring stack"

        wait_for_k3s
        wait_for_traefik
        wait_for_certificate

        helm_repo_add "prometheus-community" "https://prometheus-community.github.io/helm-charts"
        setup_namespace "${ns}"

        # Generate or reuse Grafana admin password
        GRAFANA_ADMIN_PASSWORD=$(get_secret_value "${ns}" "grafana-admin-credentials" "ADMIN_PASSWORD")
        [ -z "$GRAFANA_ADMIN_PASSWORD" ] && GRAFANA_ADMIN_PASSWORD=$(generate_password 24)

        # Install kube-prometheus-stack
        helm_install "kube-prometheus-stack" "prometheus-community/kube-prometheus-stack" "${ns}" "15m" \
          "grafana.adminPassword=$GRAFANA_ADMIN_PASSWORD" \
          "grafana.persistence.enabled=true" \
          "grafana.persistence.size=2Gi" \
          "grafana.initChownData.enabled=false" \
          "prometheus.prometheusSpec.retention=15d" \
          "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi" \
          "alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=2Gi" \
          "grafana.ingress.enabled=false" \
          "prometheus.ingress.enabled=false" \
          "alertmanager.ingress.enabled=false" \
          "grafana.grafana\.ini.server.root_url=https://$(hostname grafana)" \
          "prometheus.prometheusSpec.resources.requests.cpu=100m" \
          "prometheus.prometheusSpec.resources.requests.memory=512Mi" \
          "prometheus.prometheusSpec.resources.limits.memory=2Gi" \
          "grafana.resources.requests.cpu=50m" \
          "grafana.resources.requests.memory=128Mi" \
          "grafana.resources.limits.memory=512Mi" \
          "grafana.additionalDataSources[0].name=Loki" \
          "grafana.additionalDataSources[0].type=loki" \
          "grafana.additionalDataSources[0].url=http://loki:3100" \
          "grafana.additionalDataSources[0].access=proxy"

        wait_for_pod "${ns}" "app.kubernetes.io/name=grafana" 300

        # IngressRoutes
        create_ingress_route "grafana" "${ns}" "$(hostname grafana)" "kube-prometheus-stack-grafana" "80"
        create_ingress_route "prometheus" "${ns}" "$(hostname prometheus)" "kube-prometheus-stack-prometheus" "9090" "authentik-forward-auth:traefik-system"
        create_ingress_route "alertmanager" "${ns}" "$(hostname alertmanager)" "kube-prometheus-stack-alertmanager" "9093" "authentik-forward-auth:traefik-system"

        store_credentials "${ns}" "grafana-admin-credentials" \
          "ADMIN_USER=admin" "ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD"

        print_success "Monitoring stack" \
          "Grafana:      https://$(hostname grafana)" \
          "Prometheus:   https://$(hostname prometheus) (ForwardAuth)" \
          "Alertmanager: https://$(hostname alertmanager) (ForwardAuth)" \
          "Credentials stored in K8s secret grafana-admin-credentials"

        create_marker "${markerFile}"
      '';
    };
  };

  # Grafana OIDC configuration (separate service)
  systemd.services.grafana-oidc-setup = {
    description = "Configure Grafana OIDC with Authentik SSO";
    # After media (SSO already configured)
    after = [
      "k3s-media.target"
      "monitoring-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [
      "monitoring-setup.service"
      "authentik-sso-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "grafana-oidc-setup" ''
                ${k8s.libShSource}
                setup_preamble "/var/lib/grafana-oidc-setup-done" "Grafana OIDC"

                # Wait for SSO credentials
                wait_for_resource "secret" "${ns}" "authentik-sso-credentials" 300

                GRAFANA_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.GRAFANA_CLIENT_SECRET}' | base64 -d)
                if [ -z "$GRAFANA_CLIENT_SECRET" ]; then
                  echo "No GRAFANA_CLIENT_SECRET found, skipping OIDC setup"
                  exit 0
                fi

                # Create OIDC secret
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: grafana-oidc-env
          namespace: ${ns}
        type: Opaque
        stringData:
          GF_SERVER_ROOT_URL: "https://$(hostname grafana)"
          GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
          GF_AUTH_GENERIC_OAUTH_NAME: "Authentik"
          GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP: "true"
          GF_AUTH_GENERIC_OAUTH_CLIENT_ID: "grafana"
          GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: "$GRAFANA_CLIENT_SECRET"
          GF_AUTH_GENERIC_OAUTH_SCOPES: "openid email profile"
          GF_AUTH_GENERIC_OAUTH_AUTH_URL: "https://$(hostname auth)/application/o/authorize/"
          GF_AUTH_GENERIC_OAUTH_TOKEN_URL: "https://$(hostname auth)/application/o/token/"
          GF_AUTH_GENERIC_OAUTH_API_URL: "https://$(hostname auth)/application/o/userinfo/"
          GF_AUTH_GENERIC_OAUTH_SIGNOUT_REDIRECT_URL: "https://$(hostname auth)/application/o/grafana/end-session/"
          GF_AUTH_GENERIC_OAUTH_USE_PKCE: "true"
          GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: "contains(groups, 'admins') && 'Admin' || 'Viewer'"
        EOF

                # Patch Grafana deployment to use envFrom secret
                if ! $KUBECTL get deployment kube-prometheus-stack-grafana -n ${ns} -o jsonpath='{.spec.template.spec.containers[*].envFrom}' | grep -q "grafana-oidc-env"; then
                  $KUBECTL patch deployment kube-prometheus-stack-grafana -n ${ns} --type=strategic -p='{
                    "spec": {
                      "template": {
                        "spec": {
                          "containers": [{
                            "name": "grafana",
                            "envFrom": [{"secretRef": {"name": "grafana-oidc-env"}}]
                          }]
                        }
                      }
                    }
                  }'
                else
                  # Secret already referenced but content may have changed -- restart to pick up new values
                  $KUBECTL rollout restart deployment/kube-prometheus-stack-grafana -n ${ns}
                fi
                wait_for_pod "${ns}" "app.kubernetes.io/name=grafana" 180

                print_success "Grafana OIDC" \
                  "URL: https://$(hostname grafana)" \
                  "Login: Click 'Sign in with Authentik'" \
                  "Users in 'admins' group -> Admin, others -> Viewer"

                create_marker "/var/lib/grafana-oidc-setup-done"
      '';
    };
  };
}
