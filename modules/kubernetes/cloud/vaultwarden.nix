{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "vaultwarden";
  markerFile = "/var/lib/vaultwarden-setup-done";
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
                setup_preamble "${markerFile}" "Vaultwarden"

                wait_for_k3s
                wait_for_traefik
                wait_for_certificate

                helm_repo_add "guerzon" "https://guerzon.github.io/vaultwarden"
                setup_namespace "${ns}"

                # Install Vaultwarden with persistence
                helm_install "vaultwarden" "guerzon/vaultwarden" "${ns}" "5m" \
                  "domain=https://$(hostname vault)" \
                  "signupsAllowed=true" \
                  "signupsVerify=false" \
                  "invitationsAllowed=true" \
                  "showPasswordHint=false" \
                  "websocket.enabled=true" \
                  "storage.data.name=vaultwarden-data" \
                  "storage.data.size=10Gi" \
                  "storage.data.class=local-path" \
                  "storage.data.accessMode=ReadWriteOnce" \
                  "ingress.enabled=false"

                wait_for_pod "${ns}" "app.kubernetes.io/name=vaultwarden" 300

                # IngressRoute
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: vaultwarden
          namespace: ${ns}
        spec:
          entryPoints:
            - websecure
          routes:
            - match: Host(\`$(hostname vault)\`)
              kind: Rule
              services:
                - name: vaultwarden
                  port: 80
          tls:
            secretName: $CERT_SECRET
        EOF

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
      "k3s-media.target"
      "vaultwarden-setup.service"
      "vaultwarden-admin-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-media.target" ];
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
        setup_preamble "/var/lib/vaultwarden-sso-setup-done" "Vaultwarden SSO"

        # Wait for SSO credentials
        wait_for_resource "secret" "${ns}" "authentik-sso-credentials" 300

        SSO_CLIENT_ID=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.VAULTWARDEN_CLIENT_ID}' | base64 -d)
        SSO_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.VAULTWARDEN_CLIENT_SECRET}' | base64 -d)

        if [ -z "$SSO_CLIENT_SECRET" ]; then
          echo "No SSO credentials found, skipping"
          exit 0
        fi

        # Read ADMIN_TOKEN and SIGNUPS_ALLOWED before helm upgrade resets env vars
        EXISTING_ADMIN_TOKEN=$($KUBECTL get statefulset vaultwarden -n ${ns} \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_TOKEN")].value}' 2>/dev/null || true)
        EXISTING_SIGNUPS=$($KUBECTL get statefulset vaultwarden -n ${ns} \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SIGNUPS_ALLOWED")].value}' 2>/dev/null || true)

        # Upgrade with SSO enabled and persistence
        helm_install "vaultwarden" "guerzon/vaultwarden" "${ns}" "5m" \
          "domain=https://$(hostname vault)" \
          "signupsAllowed=true" \
          "signupsVerify=false" \
          "invitationsAllowed=true" \
          "showPasswordHint=false" \
          "websocket.enabled=true" \
          "storage.data.name=vaultwarden-data" \
          "storage.data.size=10Gi" \
          "storage.data.class=local-path" \
          "storage.data.accessMode=ReadWriteOnce" \
          "ingress.enabled=false" \
          "env.SSO_ENABLED=true"

        # Restore ADMIN_TOKEN and env vars after helm upgrade
        EXTRA_ENV_ARGS=""
        if [ -n "$EXISTING_ADMIN_TOKEN" ]; then
          EXTRA_ENV_ARGS="ADMIN_TOKEN=$EXISTING_ADMIN_TOKEN"
          echo "Restoring ADMIN_TOKEN after helm upgrade"
        fi
        if [ "$EXISTING_SIGNUPS" = "false" ]; then
          EXTRA_ENV_ARGS="$EXTRA_ENV_ARGS SIGNUPS_ALLOWED=false"
          echo "Restoring SIGNUPS_ALLOWED=false after helm upgrade"
        fi

        $KUBECTL set env statefulset/vaultwarden -n ${ns} \
          SSO_CLIENT_ID="$SSO_CLIENT_ID" \
          SSO_CLIENT_SECRET="$SSO_CLIENT_SECRET" \
          SSO_AUTHORITY="https://$(hostname auth)/application/o/vaultwarden/" \
          SSO_PKCE="true" \
          $EXTRA_ENV_ARGS

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
