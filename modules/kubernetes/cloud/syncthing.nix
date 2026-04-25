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
  ns = "syncthing";
  markerFile = "/var/lib/syncthing-setup-done";
  ldapEnabled = serverConfig.authentik.ldap.enable or false;
in
{
  systemd.services.syncthing-setup = {
    description = "Setup Syncthing file synchronization";
    after = [ "k3s-core.target" ] ++ lib.optional ldapEnabled "authentik-ldap-setup.service";
    requires = [ "k3s-core.target" ];
    wants = lib.optional ldapEnabled "authentik-ldap-setup.service";
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "syncthing-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Syncthing"

        wait_for_k3s
        ensure_namespace "${ns}"

        # PVCs — storageClassName: longhorn is declared explicitly so
        # apply stays idempotent against pre-existing PVCs (SC is
        # immutable after bind).
        ${k8s.applyManifestsScript {
          name = "syncthing-pvcs";
          manifests = [ ./syncthing-pvcs.yaml ];
          substitutions = {
            NAMESPACE = ns;
          };
        }}

        # Deployment (Syncthing uses different paths than LinuxServer)
        ${k8s.applyManifestsScript {
          name = "syncthing-app";
          manifests = [ ./syncthing-app.yaml ];
          substitutions = {
            NAMESPACE = ns;
          };
        }}

        wait_for_pod "${ns}" "app=syncthing" 180

        # IngressRoute
        create_ingress_route "syncthing" "${ns}" "$(hostname sync)" "syncthing" "8384"

        # Get Syncthing API key from config.xml
        SYNC_API_KEY=$($KUBECTL exec -n ${ns} deploy/syncthing -- \
          sed -n 's/.*<apikey>\(.*\)<\/apikey>.*/\1/p' /var/syncthing/config/config.xml 2>/dev/null || echo "")

        if [ -n "$SYNC_API_KEY" ]; then
          ${
            if ldapEnabled then
              ''
                # Configure LDAP authentication (Authentik LDAP outpost)
                echo "Configuring LDAP authentication..."

                # Wait for LDAP service to be available
                for i in $(seq 1 30); do
                  if $KUBECTL get svc -n authentik authentik-ldap &>/dev/null; then
                    break
                  fi
                  sleep 5
                done

                # Set LDAP config
                $KUBECTL exec -n ${ns} deploy/syncthing -- \
                  curl -s -X PATCH "http://localhost:8384/rest/config/ldap" \
                  -H "X-API-Key: $SYNC_API_KEY" \
                  -H "Content-Type: application/json" \
                  -d '{
                    "address": "authentik-ldap.authentik.svc.cluster.local:389",
                    "bindDN": "cn=%s,ou=users,dc=nas,dc=local",
                    "transport": "plain",
                    "insecureSkipVerify": false,
                    "searchBaseDN": "",
                    "searchFilter": ""
                  }' >/dev/null 2>&1

                # Set GUI to LDAP auth mode and clear local credentials
                $KUBECTL exec -n ${ns} deploy/syncthing -- \
                  curl -s -X PATCH "http://localhost:8384/rest/config/gui" \
                  -H "X-API-Key: $SYNC_API_KEY" \
                  -H "Content-Type: application/json" \
                  -d '{"authMode": "ldap", "user": "", "password": ""}' >/dev/null 2>&1

                echo "Syncthing: LDAP authentication configured (Authentik)"

                store_credentials "${ns}" "syncthing-credentials" \
                  "AUTH=ldap" "LDAP_SERVER=authentik-ldap.authentik.svc.cluster.local:389" \
                  "API_KEY=$SYNC_API_KEY" "URL=https://$(hostname sync)"
              ''
            else
              ''
                # Configure local GUI authentication
                CURRENT_USER=$($KUBECTL exec -n ${ns} deploy/syncthing -- \
                  curl -s "http://localhost:8384/rest/config/gui" \
                  -H "X-API-Key: $SYNC_API_KEY" 2>/dev/null | $JQ -r '.user // empty')

                if [ -z "$CURRENT_USER" ]; then
                  SYNC_PASS=$(generate_password 16)

                  $KUBECTL exec -n ${ns} deploy/syncthing -- \
                    curl -s -X PATCH "http://localhost:8384/rest/config/gui" \
                    -H "X-API-Key: $SYNC_API_KEY" \
                    -H "Content-Type: application/json" \
                    -d "{\"user\": \"${serverConfig.adminUser}\", \"password\": \"$SYNC_PASS\"}" >/dev/null 2>&1

                  store_credentials "${ns}" "syncthing-credentials" \
                    "USER=${serverConfig.adminUser}" "PASSWORD=$SYNC_PASS" \
                    "API_KEY=$SYNC_API_KEY" "URL=https://$(hostname sync)"
                  echo "Syncthing: GUI authentication configured"
                else
                  echo "Syncthing: GUI authentication already set (user: $CURRENT_USER)"
                fi
              ''
          }
        fi

        print_success "Syncthing" \
          "URL: https://$(hostname sync)"

        create_marker "${markerFile}"
      '';
    };
  };
}
