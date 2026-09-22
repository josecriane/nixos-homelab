{
  k8s,
  lib,
  pkgs,
  ...
}:

let
  ns = "vaultwarden";
  markerFile = "/var/lib/vaultwarden-setup-done";
  chartVersion = "0.46.2";
  credSecretName = "vaultwarden-admin-credentials";
  tokenSecretName = "vaultwarden-admin-token";
  ssoSecretName = "authentik-sso-credentials";

  # Shared helpers, sourced by both setup services so a single set of chart
  # values is used everywhere. Two callers with different values would flip the
  # release back and forth on every deploy.
  helpers = ''
    vaultwarden_migrate_inline_token() {
      local inline
      inline=$($KUBECTL get statefulset vaultwarden -n ${ns} \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_TOKEN")].value}' 2>/dev/null || true)
      if [ -z "$inline" ]; then
        return 0
      fi

      echo "Migrating the inline ADMIN_TOKEN to ${tokenSecretName}"
      $KUBECTL scale statefulset/vaultwarden -n ${ns} --replicas=0
      $KUBECTL wait --for=delete pod/vaultwarden-0 -n ${ns} --timeout=180s || true
      $KUBECTL set env statefulset/vaultwarden -n ${ns} ADMIN_TOKEN- >/dev/null
    }

    vaultwarden_ensure_token_secret() {
      local hash
      hash=$(get_secret_value "${ns}" "${tokenSecretName}" "ADMIN_TOKEN")
      if [ -z "$hash" ]; then
        hash=$(get_secret_value "${ns}" "${credSecretName}" "ADMIN_TOKEN_HASH")
      fi
      if [ -z "$hash" ]; then
        hash=$($KUBECTL get statefulset vaultwarden -n ${ns} \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_TOKEN")].value}' 2>/dev/null || true)
      fi
      store_credentials "${ns}" "${tokenSecretName}" "ADMIN_TOKEN=$hash"
    }

    vaultwarden_helm_apply() {
      local signups="true"
      if [ -n "$(get_secret_value "${ns}" "${credSecretName}" "USER_EMAIL")" ]; then
        signups="false"
      fi

      local -a sso_sets=()
      if [ -n "$(get_secret_value "${ns}" "${ssoSecretName}" "VAULTWARDEN_CLIENT_SECRET")" ]; then
        sso_sets=(
          "sso.enabled=true"
          "sso.authority=https://$(hostname auth)/application/o/vaultwarden/"
          "sso.pkce=true"
          "sso.existingSecret=${ssoSecretName}"
          "sso.clientId.existingSecretKey=VAULTWARDEN_CLIENT_ID"
          "sso.clientSecret.existingSecretKey=VAULTWARDEN_CLIENT_SECRET"
        )
        echo "SSO credentials present, enabling SSO"
      else
        echo "No SSO credentials yet, installing without SSO"
      fi

      helm_install "vaultwarden" "guerzon/vaultwarden" "${ns}" "5m" "${chartVersion}" \
        "domain=https://$(hostname vault)" \
        "signupsAllowed=$signups" \
        "signupsVerify=false" \
        "invitationsAllowed=true" \
        "showPasswordHint=false" \
        "websocket.enabled=true" \
        "storage.data.name=vaultwarden-data" \
        "storage.data.size=10Gi" \
        "storage.data.class=local-path" \
        "storage.data.accessMode=ReadWriteOnce" \
        "ingress.enabled=false" \
        "adminToken.existingSecret=${tokenSecretName}" \
        "adminToken.existingSecretKey=ADMIN_TOKEN" \
        "''${sso_sets[@]}"
    }
  '';
in
{
  systemd.services.vaultwarden-setup = {
    description = "Setup Vaultwarden password manager";
    after = [ "k3s-storage.target" ];
    requires = [ "k3s-storage.target" ];
    # TIER 3: Core
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vaultwarden-setup" ''
        ${k8s.libShSource}
        ${helpers}
        setup_preamble "${markerFile}" "Vaultwarden"

        wait_for_k3s
        wait_for_traefik
        wait_for_certificate

        helm_repo_add "guerzon" "https://guerzon.github.io/vaultwarden"
        ensure_namespace "${ns}"

        vaultwarden_ensure_token_secret
        vaultwarden_migrate_inline_token

        vaultwarden_helm_apply

        wait_for_pod "${ns}" "app.kubernetes.io/name=vaultwarden" 300

        create_ingress_route "vaultwarden" "${ns}" "$(hostname vault)" "vaultwarden" "80"

        print_success "Vaultwarden" \
          "URLs:" \
          "  URL: https://$(hostname vault)" \
          "" \
          "Register your first account to become admin"

        create_marker "${markerFile}"
      '';
    };
  };

  # SSO configuration service
  systemd.services.vaultwarden-sso-setup = {
    description = "Configure Vaultwarden SSO with Authentik";
    # After media (SSO already configured)
    after = [
      "k3s-apps.target"
      "vaultwarden-setup.service"
      "vaultwarden-admin-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [
      "vaultwarden-setup.service"
      "vaultwarden-admin-setup.service"
      "authentik-sso-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vaultwarden-sso-setup" ''
        ${k8s.libShSource}
        ${helpers}
        setup_preamble "/var/lib/vaultwarden-sso-setup-done" "Vaultwarden SSO"

        # Wait for SSO credentials
        wait_for_resource "secret" "${ns}" "${ssoSecretName}" 300

        if [ -z "$(get_secret_value "${ns}" "${ssoSecretName}" "VAULTWARDEN_CLIENT_SECRET")" ]; then
          echo "No SSO credentials found, skipping"
          exit 0
        fi

        vaultwarden_ensure_token_secret
        vaultwarden_migrate_inline_token

        vaultwarden_helm_apply

        wait_for_pod "${ns}" "app.kubernetes.io/name=vaultwarden" 300

        print_success "Vaultwarden SSO" \
          "URLs:" \
          "  URL: https://$(hostname vault)" \
          "" \
          "Login: Use 'Enterprise SSO' in the app"

        create_marker "/var/lib/vaultwarden-sso-setup-done"
      '';
    };
  };
}
