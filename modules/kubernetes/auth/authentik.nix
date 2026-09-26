{
  k8s,
  config,
  lib,
  serverConfig,
  secretsPath,
  ...
}:

let
  ns = "authentik";
  chartVersion = "2026.8.3";

  runtimeScript = ''
    EXISTING_SECRET=$($KUBECTL get secret authentik -n ${ns} -o jsonpath='{.data.authentik-secret-key}' 2>/dev/null | base64 -d 2>/dev/null || true)
    EXISTING_PG_PASS=$($KUBECTL get secret authentik-postgresql -n ${ns} -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

    AUTHENTIK_SECRET_KEY=''${EXISTING_SECRET:-$(generate_hex 32)}
    POSTGRES_PASSWORD=''${EXISTING_PG_PASS:-$(generate_hex 16)}

    EXISTING_BOOTSTRAP=$(get_secret_value "${ns}" "authentik-setup-credentials" "BOOTSTRAP_TOKEN")
    BOOTSTRAP_TOKEN=''${EXISTING_BOOTSTRAP:-$(generate_hex 32)}
    AUTHENTIK_ADMIN_PASSWORD=$(cat ${config.age.secrets.authentik-admin-password.path})
  '';

  preScript = ''
    wait_for_traefik
    wait_for_certificate
  '';

  extraScript = ''
    EXISTING_API_TOKEN=$(get_secret_value "${ns}" "authentik-api-token" "TOKEN")
    if [ -z "$EXISTING_API_TOKEN" ]; then
      echo "Creating persistent API token..."
      API_KEY=$($KUBECTL exec -n ${ns} deploy/authentik-server -- ak shell -c "
    from authentik.core.models import Token, TokenIntents, User
    user = User.objects.get(username='akadmin')
    token, _ = Token.objects.get_or_create(
        identifier='sso-automation',
        defaults={'user': user, 'intent': TokenIntents.INTENT_API, 'expiring': False}
    )
    print(token.key)
    " 2>/dev/null | tail -1)
      if [ -n "$API_KEY" ]; then
        store_credentials "${ns}" "authentik-api-token" "TOKEN=$API_KEY"
        echo "API token saved to K8s secret authentik-api-token"
      else
        echo "WARN: Could not create API token (sso-setup will use bootstrap token)"
      fi
    fi

    store_credentials "${ns}" "authentik-setup-credentials" \
      "USER=akadmin" "PASSWORD=$AUTHENTIK_ADMIN_PASSWORD" \
      "EMAIL=${serverConfig.authentik.adminEmail}" "URL=https://$(hostname auth)" \
      "AUTHENTIK_SECRET_KEY=$AUTHENTIK_SECRET_KEY" "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
      "BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN"
  '';

  release = k8s.createHelmRelease {
    name = "authentik";
    namespace = ns;
    tier = "core";
    timeout = "25m";
    repo = {
      name = "authentik";
      url = "https://charts.goauthentik.io";
    };
    chart = "authentik/authentik";
    version = chartVersion;
    valuesFile = ./values-authentik.yaml;
    substitutions = {
      ADMIN_EMAIL = serverConfig.authentik.adminEmail;
    };
    runtimeSets = [
      "authentik.secret_key=$AUTHENTIK_SECRET_KEY"
      "authentik.postgresql.password=$POSTGRES_PASSWORD"
      "authentik.bootstrap_password=$AUTHENTIK_ADMIN_PASSWORD"
      "authentik.bootstrap_token=$BOOTSTRAP_TOKEN"
      "postgresql.auth.password=$POSTGRES_PASSWORD"
    ];
    inherit runtimeScript preScript extraScript;
    waitFor = "authentik-server";
    ingress = {
      host = "auth";
      service = "authentik-server";
      port = 80;
    };
  };
in
lib.recursiveUpdate release {
  age.secrets.authentik-admin-password = {
    file = "${secretsPath}/authentik-admin-password.age";
  };
}
