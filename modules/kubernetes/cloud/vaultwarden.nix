{
  k8s,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  ns = "vaultwarden";
  markerFile = "/var/lib/vaultwarden-setup-done";
  chartVersion = "0.46.2";
  credSecretName = "vaultwarden-admin-credentials";
  tokenSecretName = "vaultwarden-admin-token";
  ssoSecretName = "authentik-sso-credentials";
  domain = "${serverConfig.subdomain}.${serverConfig.domain}";

  runtimeScript = ''
    signups="true"
    if [ -n "$(get_secret_value "${ns}" "${credSecretName}" "USER_EMAIL")" ]; then
      signups="false"
    fi

    if [ -n "$(get_secret_value "${ns}" "${ssoSecretName}" "VAULTWARDEN_CLIENT_SECRET")" ]; then
      EXTRA_SETS+=(
        "sso.enabled=true"
        "sso.authority=https://auth.${domain}/application/o/vaultwarden/"
        "sso.pkce=true"
        "sso.existingSecret=${ssoSecretName}"
        "sso.clientId.existingSecretKey=VAULTWARDEN_CLIENT_ID"
        "sso.clientSecret.existingSecretKey=VAULTWARDEN_CLIENT_SECRET"
      )
      echo "SSO credentials present, enabling SSO"
    else
      echo "No SSO credentials yet, installing without SSO"
    fi
  '';

  preScript = ''
    wait_for_traefik
    wait_for_certificate

    token_hash=$(get_secret_value "${ns}" "${tokenSecretName}" "ADMIN_TOKEN")
    if [ -z "$token_hash" ]; then
      token_hash=$(get_secret_value "${ns}" "${credSecretName}" "ADMIN_TOKEN_HASH")
    fi
    if [ -z "$token_hash" ]; then
      token_hash=$($KUBECTL get statefulset vaultwarden -n ${ns} \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_TOKEN")].value}' 2>/dev/null || true)
    fi
    store_credentials "${ns}" "${tokenSecretName}" "ADMIN_TOKEN=$token_hash"

    inline_token=$($KUBECTL get statefulset vaultwarden -n ${ns} \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_TOKEN")].value}' 2>/dev/null || true)
    if [ -n "$inline_token" ]; then
      echo "Migrating the inline ADMIN_TOKEN to ${tokenSecretName}"
      $KUBECTL scale statefulset/vaultwarden -n ${ns} --replicas=0
      $KUBECTL wait --for=delete pod/vaultwarden-0 -n ${ns} --timeout=180s || true
      $KUBECTL set env statefulset/vaultwarden -n ${ns} ADMIN_TOKEN- >/dev/null
    fi
  '';

  release = k8s.createHelmRelease {
    name = "vaultwarden";
    namespace = ns;
    tier = "core";
    timeout = "5m";
    repo = {
      name = "guerzon";
      url = "https://guerzon.github.io/vaultwarden";
    };
    chart = "guerzon/vaultwarden";
    version = chartVersion;
    valuesFile = ./values-vaultwarden.yaml;
    substitutions = {
      TOKEN_SECRET = tokenSecretName;
    };
    runtimeSets = [ "signupsAllowed=$signups" ];
    inherit runtimeScript preScript;
    ingress = {
      host = "vault";
      service = "vaultwarden";
      port = 80;
    };
  };
in
lib.recursiveUpdate release {
  systemd.services.vaultwarden-sso-setup = {
    description = "Re-apply Vaultwarden once its SSO credentials exist";
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

        wait_for_k3s
        wait_for_resource "secret" "${ns}" "${ssoSecretName}" 300

        if [ -z "$(get_secret_value "${ns}" "${ssoSecretName}" "VAULTWARDEN_CLIENT_SECRET")" ]; then
          echo "No SSO credentials found, nothing to re-apply"
          exit 0
        fi

        ENABLED=$($HELM get values vaultwarden -n ${ns} -o json 2>/dev/null | $JQ -r '.sso.enabled // false')
        if [ "$ENABLED" = "true" ]; then
          echo "The release already has SSO enabled, nothing to do"
          exit 0
        fi

        echo "Invalidating ${markerFile} so vaultwarden-setup re-applies with SSO"
        rm -f "${markerFile}"
        systemctl restart --no-block vaultwarden-setup.service
      '';
    };
  };
}
