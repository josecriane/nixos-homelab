{
  config,
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  secretsPath,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "authentik";
  markerFile = "/var/lib/authentik-setup-done";
in
{
  age.secrets.authentik-admin-password = {
    file = "${secretsPath}/authentik-admin-password.age";
  };

  systemd.services.authentik-setup = {
    description = "Setup Authentik SSO/Identity Provider";
    after = [ "k3s-storage.target" ];
    requires = [ "k3s-storage.target" ];
    # TIER 3: Core
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "authentik-setup" ''
                ${k8s.libShSource}

                setup_preamble "${markerFile}" "Authentik"
                wait_for_k3s
                wait_for_traefik
                wait_for_certificate
                helm_repo_add "authentik" "https://charts.goauthentik.io"
                ensure_namespace "${ns}"

                # Reuse existing secrets or generate new ones
                EXISTING_SECRET=$($KUBECTL get secret authentik -n ${ns} -o jsonpath='{.data.authentik-secret-key}' 2>/dev/null | base64 -d 2>/dev/null || true)
                EXISTING_PG_PASS=$($KUBECTL get secret authentik-postgresql -n ${ns} -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

                AUTHENTIK_SECRET_KEY=''${EXISTING_SECRET:-$(generate_hex 32)}
                POSTGRES_PASSWORD=''${EXISTING_PG_PASS:-$(generate_hex 16)}

                # Reuse existing bootstrap token (Authentik stores it in DB on first boot;
                # regenerating creates a mismatch between K8s secret and DB)
                EXISTING_BOOTSTRAP=$(get_secret_value "${ns}" "authentik-setup-credentials" "BOOTSTRAP_TOKEN")
                BOOTSTRAP_TOKEN=''${EXISTING_BOOTSTRAP:-$(generate_hex 32)}
                AUTHENTIK_ADMIN_PASSWORD=$(cat ${config.age.secrets.authentik-admin-password.path})

                # Install Authentik
                helm_install "authentik" "authentik/authentik" "${ns}" "10m" \
                  "authentik.secret_key=$AUTHENTIK_SECRET_KEY" \
                  "authentik.error_reporting.enabled=false" \
                  "authentik.postgresql.password=$POSTGRES_PASSWORD" \
                  "authentik.bootstrap_password=$AUTHENTIK_ADMIN_PASSWORD" \
                  "authentik.bootstrap_token=$BOOTSTRAP_TOKEN" \
                  "authentik.bootstrap_email=${serverConfig.authentik.adminEmail}" \
                  "postgresql.enabled=true" \
                  "postgresql.auth.password=$POSTGRES_PASSWORD" \
                  "postgresql.primary.persistence.enabled=true" \
                  "postgresql.primary.persistence.size=2Gi" \
                  "redis.enabled=true" \
                  "redis.master.persistence.enabled=true" \
                  "redis.master.persistence.size=1Gi" \
                  "server.ingress.enabled=false" \
                  "server.replicas=1" \
                  "worker.replicas=1"

                wait_for_pod "${ns}" "app.kubernetes.io/name=authentik,app.kubernetes.io/component=server" 600

                create_ingress_route "authentik" "${ns}" "$(hostname auth)" "authentik-server" "80"

                # Create persistent API token for sso-setup service (via Django shell)
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

                # Save credentials to K8s secret
                store_credentials "${ns}" "authentik-setup-credentials" \
                  "USER=akadmin" "PASSWORD=$AUTHENTIK_ADMIN_PASSWORD" \
                  "EMAIL=${serverConfig.authentik.adminEmail}" "URL=https://$(hostname auth)" \
                  "AUTHENTIK_SECRET_KEY=$AUTHENTIK_SECRET_KEY" "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
                  "BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN"

                print_success "Authentik" \
                  "URLs:" \
                  "  URL: https://$(hostname auth)" \
                  "" \
                  "Credentials:" \
                  "  User: akadmin" \
                  "  Password: (configured in setup.sh)" \
                  "" \
                  "Credentials stored in K8s secret authentik-setup-credentials"

                create_marker "${markerFile}"
      '';
    };
  };
}
