{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/jellyfin-setup-done";
in
{
  systemd.services.jellyfin-setup = {
    description = "Setup Jellyfin media server with SSO";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [ "nfs-storage-setup.service" ];
    # TIER 4: Media
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "jellyfin-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "Jellyfin"

                wait_for_k3s
                wait_for_traefik
                wait_for_certificate

                helm_repo_add "jellyfin" "https://jellyfin.github.io/jellyfin-helm"
                setup_namespace "${ns}"
                wait_for_shared_data "${ns}"

                # PVCs (config only, media uses shared-data)
                create_pvc "jellyfin-config" "${ns}" "5Gi"

                # Install Jellyfin with shared-data for media
                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: jellyfin
          namespace: ${ns}
          labels:
            app.kubernetes.io/name: jellyfin
        spec:
          replicas: 1
          selector:
            matchLabels:
              app.kubernetes.io/name: jellyfin
          template:
            metadata:
              labels:
                app.kubernetes.io/name: jellyfin
            spec:
              securityContext:
                supplementalGroups:
                  - 26
                  - 303
              containers:
              - name: jellyfin
                image: jellyfin/jellyfin:10.11.6
                ports:
                - containerPort: 8096
                resources:
                  requests:
                    cpu: 500m
                    memory: 1Gi
                  limits:
                    memory: 6Gi
                env:
                - name: JELLYFIN_PublishedServerUrl
                  value: "https://${k8s.hostname "jellyfin"}"
                volumeMounts:
                - name: config
                  mountPath: /config
                - name: cache
                  mountPath: /cache
                - name: data
                  mountPath: /data
                  subPath: media
                - name: dri
                  mountPath: /dev/dri
              volumes:
              - name: config
                persistentVolumeClaim:
                  claimName: jellyfin-config
              - name: cache
                emptyDir: {}
              - name: data
                persistentVolumeClaim:
                  claimName: shared-data
              - name: dri
                hostPath:
                  path: /dev/dri
                  type: Directory
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: jellyfin
          namespace: ${ns}
        spec:
          selector:
            app.kubernetes.io/name: jellyfin
          ports:
          - port: 8096
            targetPort: 8096
        EOF

                wait_for_pod "${ns}" "app.kubernetes.io/name=jellyfin" 300

                # ============================================
                # AUTOMATIC CONFIGURATION VIA API
                # ============================================
                pkill -f 'port-forward.*jellyfin' 2>/dev/null || true
                sleep 2
                $KUBECTL port-forward -n ${ns} svc/jellyfin 18096:8096 &
                PF_PID=$!
                sleep 5

                JELLYFIN_URL="http://localhost:18096"

                # Wait for API
                for i in $(seq 1 30); do
                  if $CURL -s "$JELLYFIN_URL/System/Info/Public" 2>/dev/null | grep -q "ServerName"; then
                    echo "API available"
                    break
                  fi
                  sleep 3
                done

                WIZARD_COMPLETED=$($CURL -s "$JELLYFIN_URL/System/Info/Public" 2>/dev/null | $JQ -r '.StartupWizardCompleted // false')

                if [ "$WIZARD_COMPLETED" = "false" ]; then
                  echo "Running wizard..."
                  sleep 10

                  ADMIN_PASSWORD=$(generate_password 24)

                  # Configure language
                  $CURL -s -X POST "$JELLYFIN_URL/Startup/Configuration" \
                    -H "Content-Type: application/json" \
                    -d '{"UICulture":"es","MetadataCountryCode":"ES","PreferredMetadataLanguage":"es"}' 2>/dev/null || true
                  sleep 2

                  # Get current wizard user
                  CURRENT_USER_NAME=$($CURL -s "$JELLYFIN_URL/Startup/User" 2>/dev/null | $JQ -r '.Name // "admin"')

                  # Set password
                  USER_CREATED="false"
                  for attempt in $(seq 1 5); do
                    USER_RESPONSE=$($CURL -s -w "\n%{http_code}" -X POST "$JELLYFIN_URL/Startup/User" \
                      -H "Content-Type: application/json" \
                      -d "{\"Name\":\"$CURRENT_USER_NAME\",\"Password\":\"$ADMIN_PASSWORD\"}" 2>/dev/null)
                    HTTP_CODE=$(echo "$USER_RESPONSE" | tail -1)
                    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
                      USER_CREATED="true"
                      break
                    fi
                    sleep 3
                  done

                  # Complete wizard
                  $CURL -s -X POST "$JELLYFIN_URL/Startup/Complete" -H "Content-Type: application/json" 2>/dev/null || true
                  sleep 3

                  if [ "$USER_CREATED" = "true" ]; then
                    store_credentials "${ns}" "jellyfin-credentials" \
                      "ADMIN_USER=$CURRENT_USER_NAME" "ADMIN_PASSWORD=$ADMIN_PASSWORD"
                  fi
                fi

                # Configure libraries
                ADMIN_USER=$(get_secret_value "${ns}" "jellyfin-credentials" "ADMIN_USER")
                ADMIN_PASSWORD=$(get_secret_value "${ns}" "jellyfin-credentials" "ADMIN_PASSWORD")
                if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASSWORD" ]; then

                  JELLYFIN_POD=$($KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=jellyfin --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
                  # Directories are created by nfs-storage-setup in /data/media/*
                  [ -n "$JELLYFIN_POD" ] && $KUBECTL exec -n ${ns} $JELLYFIN_POD -- mkdir -p /data/movies /data/movies-es /data/tv /data/tv-es /data/music 2>/dev/null || true

                  AUTH_RESPONSE=$($CURL -s -X POST "$JELLYFIN_URL/Users/AuthenticateByName" \
                    -H "Content-Type: application/json" \
                    -H "X-Emby-Authorization: MediaBrowser Client=\"Setup\", Device=\"NixOS\", DeviceId=\"setup\", Version=\"1.0\"" \
                    -d "{\"Username\":\"$ADMIN_USER\",\"Pw\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "{}")
                  ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | $JQ -r '.AccessToken // empty' 2>/dev/null || echo "")

                  if [ -n "$ACCESS_TOKEN" ]; then
                    EXISTING_LIBS=$($CURL -s "$JELLYFIN_URL/Library/VirtualFolders?api_key=$ACCESS_TOKEN" 2>/dev/null)

                    for lib_entry in "movies:Movies:/data/movies" "tvshows:TV Shows:/data/tv" "music:Music:/data/music" "movies:Peliculas ES:/data/movies-es" "tvshows:Series ES:/data/tv-es"; do
                      lib_type=$(echo "$lib_entry" | cut -d: -f1)
                      lib_name=$(echo "$lib_entry" | cut -d: -f2)
                      lib_path=$(echo "$lib_entry" | cut -d: -f3)

                      if ! echo "$EXISTING_LIBS" | grep -q "\"Name\":\"$lib_name\""; then
                        $CURL -s -X POST "$JELLYFIN_URL/Library/VirtualFolders?name=$(echo $lib_name | sed 's/ /%20/g')&collectionType=$lib_type&refreshLibrary=false&api_key=$ACCESS_TOKEN" \
                          -H "Content-Type: application/json" -d '{"LibraryOptions":{"EnableRealtimeMonitor":true,"EnableInternetProviders":true}}' 2>/dev/null || true
                        $CURL -s -X POST "$JELLYFIN_URL/Library/VirtualFolders/Paths?refreshLibrary=false&api_key=$ACCESS_TOKEN" \
                          -H "Content-Type: application/json" -d "{\"Name\":\"$lib_name\",\"Path\":\"$lib_path\"}" 2>/dev/null || true
                        echo "  Library created: $lib_name ($lib_path)"
                      fi
                    done

                    # Trigger initial library scan
                    $CURL -s -X POST "$JELLYFIN_URL/Library/Refresh?api_key=$ACCESS_TOKEN" 2>/dev/null || true

                    # Configure VA-API hardware acceleration (AMD Ryzen 5800U Vega GPU)
                    ENCODING=$($CURL -s "$JELLYFIN_URL/System/Configuration/encoding?api_key=$ACCESS_TOKEN" 2>/dev/null)
                    if [ -n "$ENCODING" ]; then
                      UPDATED=$(echo "$ENCODING" | $JQ '
                        .HardwareAccelerationType = "vaapi" |
                        .VaapiDevice = "/dev/dri/renderD128" |
                        .EnableHardwareEncoding = true |
                        .AllowHevcEncoding = true |
                        .EnableTonemapping = true |
                        .EnableDecodingColorDepth10Hevc = true |
                        .EnableDecodingColorDepth10Vp9 = true |
                        .HardwareDecodingCodecs = ["h264","hevc","mpeg2video","vc1","vp9"]
                      ')
                      $CURL -s -X POST "$JELLYFIN_URL/System/Configuration/encoding?api_key=$ACCESS_TOKEN" \
                        -H "Content-Type: application/json" -d "$UPDATED" 2>/dev/null || true
                      echo "VA-API hardware acceleration configured"
                    fi
                    echo "Library scan started"
                  fi
                fi

                kill $PF_PID 2>/dev/null || true
                sleep 2

                # ============================================
                # SSO PLUGIN CONFIGURATION
                # ============================================
                SSO_CONFIGURED="false"
                if $KUBECTL get secret authentik-sso-credentials -n ${ns} &>/dev/null; then
                  JELLYFIN_CLIENT_ID=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.JELLYFIN_CLIENT_ID}' | base64 -d)
                  JELLYFIN_CLIENT_SECRET=$($KUBECTL get secret authentik-sso-credentials -n ${ns} -o jsonpath='{.data.JELLYFIN_CLIENT_SECRET}' | base64 -d)

                  if [ -n "$JELLYFIN_CLIENT_SECRET" ]; then
                    JELLYFIN_POD=$($KUBECTL get pods -n ${ns} -l app.kubernetes.io/name=jellyfin -o jsonpath='{.items[0].metadata.name}')

                    if [ -n "$JELLYFIN_POD" ]; then
                      # Download SSO plugin
                      $KUBECTL exec -n ${ns} $JELLYFIN_POD -- mkdir -p /config/plugins/SSO-Auth
                      PLUGIN_TMP=$(mktemp -d)
                      $CURL -sL -o "$PLUGIN_TMP/sso.zip" \
                        "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v4.0.0.3/sso-authentication_4.0.0.3.zip" || true

                      if [ -f "$PLUGIN_TMP/sso.zip" ]; then
                        ${pkgs.unzip}/bin/unzip -o "$PLUGIN_TMP/sso.zip" -d "$PLUGIN_TMP/plugin" 2>/dev/null || true
                        for dll in "$PLUGIN_TMP/plugin"/*.dll; do
                          [ -f "$dll" ] && $KUBECTL cp "$dll" "${ns}/$JELLYFIN_POD:/config/plugins/SSO-Auth/$(basename $dll)" 2>/dev/null || true
                        done
                        [ -f "$PLUGIN_TMP/plugin/meta.json" ] && $KUBECTL cp "$PLUGIN_TMP/plugin/meta.json" "${ns}/$JELLYFIN_POD:/config/plugins/SSO-Auth/meta.json" 2>/dev/null || true
                        rm -rf "$PLUGIN_TMP"

                        # Restart to load plugin
                        $KUBECTL rollout restart deployment jellyfin -n ${ns}
                        $KUBECTL rollout status deployment jellyfin -n ${ns} --timeout=180s
                        sleep 5

                        pkill -f 'port-forward.*jellyfin' 2>/dev/null || true
                        sleep 2
                        $KUBECTL port-forward -n ${ns} svc/jellyfin 18096:8096 &
                        PF_PID=$!
                        sleep 5

                        for i in $(seq 1 30); do
                          if $CURL -s http://localhost:18096/System/Info/Public 2>/dev/null | grep -q "ServerName"; then
                            break
                          fi
                          sleep 3
                        done

                        ADMIN_USER=$(get_secret_value "${ns}" "jellyfin-credentials" "ADMIN_USER")
                        ADMIN_PASSWORD=$(get_secret_value "${ns}" "jellyfin-credentials" "ADMIN_PASSWORD")
                        if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASSWORD" ]; then
                          AUTH_RESPONSE=$($CURL -s -X POST "http://localhost:18096/Users/AuthenticateByName" \
                            -H "Content-Type: application/json" \
                            -H "X-Emby-Authorization: MediaBrowser Client=\"SSO-Setup\", Device=\"NixOS\", DeviceId=\"setup\", Version=\"1.0\"" \
                            -d "{\"Username\":\"$ADMIN_USER\",\"Pw\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "{}")
                          ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | $JQ -r '.AccessToken // empty' 2>/dev/null || echo "")

                          if [ -n "$ACCESS_TOKEN" ]; then
                            # Configure SSO
                            $CURL -s -X POST "http://localhost:18096/sso/OID/Add/Authentik?api_key=$ACCESS_TOKEN" \
                              -H "Content-Type: application/json" \
                              -d "{
                                \"oidEndpoint\": \"https://$(hostname auth)/application/o/jellyfin/\",
                                \"oidClientId\": \"$JELLYFIN_CLIENT_ID\",
                                \"oidSecret\": \"$JELLYFIN_CLIENT_SECRET\",
                                \"enabled\": true,
                                \"enableAuthorization\": true,
                                \"enableAllFolders\": true,
                                \"enabledFolders\": [],
                                \"adminRoles\": [\"admins\"],
                                \"roles\": [],
                                \"enableFolderRoles\": false,
                                \"folderRoleMapping\": [],
                                \"roleClaim\": \"groups\",
                                \"oidScopes\": [\"openid\", \"profile\", \"email\"],
                                \"schemeOverride\": \"https\",
                                \"disableHttps\": false,
                                \"doNotValidateEndpoints\": false,
                                \"doNotValidateIssuerName\": false
                              }" 2>/dev/null

                            # Add SSO button
                            BRANDING_TMP=$(mktemp)
                            cat > "$BRANDING_TMP" << 'ENDJSON'
        {
          "LoginDisclaimer": "<form action=\"/sso/OID/start/Authentik\" style=\"margin: 1em 0;\"><button class=\"raised block emby-button button-submit\" type=\"submit\" style=\"width: 100%; padding: 0.9em 1em; margin-bottom: 0.5em;\">Sign in with Authentik</button></form><hr style=\"margin: 1em 0; border-color: rgba(255,255,255,0.1);\">",
          "CustomCss": ".disclaimerContainer { display: block; margin-bottom: 1em; }",
          "SplashscreenEnabled": false
        }
        ENDJSON
                            $CURL -s -X POST "http://localhost:18096/System/Configuration/branding?api_key=$ACCESS_TOKEN" \
                              -H "Content-Type: application/json" -d @"$BRANDING_TMP" 2>/dev/null
                            rm -f "$BRANDING_TMP"

                            SSO_CONFIGURED="true"
                          fi
                        fi
                        kill $PF_PID 2>/dev/null || true
                      fi
                    fi
                  fi
                fi

                create_ingress_route "jellyfin" "${ns}" "$(hostname jellyfin)" "jellyfin" "8096"

                print_success "Jellyfin" \
                  "URLs:" \
                  "  URL: https://$(hostname jellyfin)" \
                  "" \
                  "Credentials stored in K8s secret jellyfin-credentials" \
                  "SSO: 'Sign in with Authentik' button on login page"

                create_marker "${markerFile}"
      '';
    };
  };
}
