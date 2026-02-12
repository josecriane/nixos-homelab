{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
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
                setup_namespace "${ns}"

                # PVCs
                create_pvc "syncthing-config" "${ns}" "1Gi"
                create_pvc "syncthing-data" "${ns}" "50Gi"

                # Deployment (Syncthing uses different paths than LinuxServer)
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: syncthing
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: syncthing
          template:
            metadata:
              labels:
                app: syncthing
            spec:
              containers:
              - name: syncthing
                image: syncthing/syncthing:2.0.14
                ports:
                - containerPort: 8384
                  name: web
                - containerPort: 22000
                  name: sync-tcp
                  protocol: TCP
                - containerPort: 22000
                  name: sync-udp
                  protocol: UDP
                - containerPort: 21027
                  name: discovery
                  protocol: UDP
                resources:
                  requests:
                    cpu: 50m
                    memory: 128Mi
                  limits:
                    memory: 512Mi
                env:
                - name: PUID
                  value: "${toString (serverConfig.puid or 1000)}"
                - name: PGID
                  value: "${toString (serverConfig.pgid or 1000)}"
                volumeMounts:
                - name: config
                  mountPath: /var/syncthing/config
                - name: data
                  mountPath: /var/syncthing/data
              volumes:
              - name: config
                persistentVolumeClaim:
                  claimName: syncthing-config
              - name: data
                persistentVolumeClaim:
                  claimName: syncthing-data
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: syncthing
          namespace: ${ns}
        spec:
          selector:
            app: syncthing
          ports:
          - name: web
            port: 8384
            targetPort: 8384
          - name: sync-tcp
            port: 22000
            targetPort: 22000
            protocol: TCP
          - name: sync-udp
            port: 22000
            targetPort: 22000
            protocol: UDP
          - name: discovery
            port: 21027
            targetPort: 21027
            protocol: UDP
        EOF

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
