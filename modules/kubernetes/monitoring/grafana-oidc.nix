# Configure Grafana OIDC with Authentik.
# The stack itself (Grafana + Prometheus + Loki + Promtail) lives in nixos-k8s;
# this module only wires up the Authentik-specific OIDC envFrom secret.
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
  ns = "monitoring";
in
{
  systemd.services.grafana-oidc-setup = {
    description = "Configure Grafana OIDC with Authentik SSO";
    after = [
      "k3s-apps.target"
      "kube-prometheus-stack-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [
      "kube-prometheus-stack-setup.service"
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

        wait_for_resource "secret" "${ns}" "authentik-sso-credentials" 300

        GRAFANA_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.GRAFANA_CLIENT_SECRET}' | base64 -d)
        if [ -z "$GRAFANA_CLIENT_SECRET" ]; then
          echo "No GRAFANA_CLIENT_SECRET found, skipping OIDC setup"
          exit 0
        fi

        AUTH_HOST=$(hostname auth)
        store_credentials "${ns}" "grafana-oidc-env" \
          "GF_SERVER_ROOT_URL=https://$(hostname grafana)" \
          "GF_AUTH_GENERIC_OAUTH_ENABLED=true" \
          "GF_AUTH_GENERIC_OAUTH_NAME=Authentik" \
          "GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true" \
          "GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana" \
          "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=$GRAFANA_CLIENT_SECRET" \
          "GF_AUTH_GENERIC_OAUTH_SCOPES=openid email profile" \
          "GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://$AUTH_HOST/application/o/authorize/" \
          "GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://$AUTH_HOST/application/o/token/" \
          "GF_AUTH_GENERIC_OAUTH_API_URL=https://$AUTH_HOST/application/o/userinfo/" \
          "GF_AUTH_GENERIC_OAUTH_SIGNOUT_REDIRECT_URL=https://$AUTH_HOST/application/o/grafana/end-session/" \
          "GF_AUTH_GENERIC_OAUTH_USE_PKCE=true" \
          "GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(groups, 'admins') && 'Admin' || 'Viewer'"

        for _i in $(seq 1 36); do
          $KUBECTL get deployment kube-prometheus-stack-grafana -n ${ns} &>/dev/null && break
          sleep 5
        done
        if ! $KUBECTL get deployment kube-prometheus-stack-grafana -n ${ns} &>/dev/null; then
          echo "Grafana deployment not found, skipping OIDC setup (will retry next boot)"
          exit 0
        fi

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
          $KUBECTL rollout restart deployment/kube-prometheus-stack-grafana -n ${ns}
        fi

        REPLICAS=$($KUBECTL get deployment kube-prometheus-stack-grafana -n ${ns} -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
        if [ "''${REPLICAS:-0}" -gt 0 ]; then
          wait_for_pod "${ns}" "app.kubernetes.io/name=grafana" 180
        else
          echo "Grafana scaled to 0, patch applied (will take effect on scale up)"
        fi

        print_success "Grafana OIDC" \
          "URL: https://$(hostname grafana)" \
          "Login: Click 'Sign in with Authentik'" \
          "Users in 'admins' group -> Admin, others -> Viewer"

        create_marker "/var/lib/grafana-oidc-setup-done"
      '';
    };
  };
}
