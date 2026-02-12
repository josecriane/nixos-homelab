{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/vaultwarden-sync-done";
in
{
  systemd.services.vaultwarden-sync = {
    description = "Sync K8s credential secrets to Vaultwarden";
    after = [
      "k3s-media.target"
      "vaultwarden-admin-setup.service"
      "syncthing-setup.service"
      "uptime-kuma-setup.service"
      "homarr-setup.service"
      "jellyseerr-oidc-config.service"
      "immich-oauth-setup.service"
      "nextcloud-setup.service"
    ];
    requires = [
      "k3s-media.target"
      "vaultwarden-admin-setup.service"
    ];
    wants = [
      "syncthing-setup.service"
      "uptime-kuma-setup.service"
      "homarr-setup.service"
      "jellyseerr-oidc-config.service"
      "immich-oauth-setup.service"
      "nextcloud-setup.service"
    ];
    # TIER 5: Extras
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vaultwarden-sync" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Vaultwarden Sync"

        wait_for_k3s

        VW_EMAIL=$(get_secret_value "vaultwarden" "vaultwarden-admin-credentials" "USER_EMAIL")
        VW_PASSWORD=$(get_secret_value "vaultwarden" "vaultwarden-admin-credentials" "USER_PASSWORD")

        if [ -z "$VW_EMAIL" ] || [ -z "$VW_PASSWORD" ]; then
          echo "No Vaultwarden credentials found, skipping sync"
          create_marker "${markerFile}"
          exit 0
        fi

        VW_URL="https://$(hostname vault)"

        # Wait for Vaultwarden to be reachable via HTTPS
        for i in $(seq 1 10); do
          if $CURL -sf "$VW_URL/alive" > /dev/null 2>&1; then
            echo "Vaultwarden reachable at $VW_URL"
            break
          fi
          if [ $i -eq 10 ]; then
            echo "ERROR: Vaultwarden not reachable at $VW_URL"
            exit 1
          fi
          sleep 3
        done

        BW="${pkgs.bitwarden-cli}/bin/bw"

        # Clean state and login
        $BW logout 2>/dev/null || true
        $BW config server "$VW_URL" 2>/dev/null || true

        BW_SESSION=""
        BW_SESSION=$($BW login "$VW_EMAIL" "$VW_PASSWORD" --raw 2>&1) || true

        if [ -z "$BW_SESSION" ] || echo "$BW_SESSION" | grep -qi "error\|failed\|invalid"; then
          echo "ERROR: Could not login to Vaultwarden"
          echo "bw output: $BW_SESSION"
          exit 1
        fi
        echo "Logged in to Vaultwarden"

        # Find org and collection
        $BW sync --session "$BW_SESSION" > /dev/null 2>&1 || true
        ORG_ID=$($BW list organizations --session "$BW_SESSION" 2>/dev/null | $JQ -r '.[] | select(.name == "Homelab Admin") | .id' 2>/dev/null || echo "")
        if [ -z "$ORG_ID" ]; then
          echo "WARN: Organization 'Homelab Admin' not found, skipping sync"
          $BW logout 2>/dev/null || true
          create_marker "${markerFile}"
          exit 0
        fi

        COLLECTION_ID=$($BW list org-collections --organizationid "$ORG_ID" --session "$BW_SESSION" 2>/dev/null | $JQ -r '.[0].id' 2>/dev/null || echo "")
        if [ -z "$COLLECTION_ID" ]; then
          echo "WARN: No collection found, skipping sync"
          $BW logout 2>/dev/null || true
          create_marker "${markerFile}"
          exit 0
        fi

        echo "Org: $ORG_ID, Collection: $COLLECTION_ID"

        # sync_service NAME NS SECRET USER_KEY PASS_KEY URL_KEY [NOTE_KEYS...]
        sync_service() {
          local item_name="$1" ns="$2" secret="$3" user_key="$4" pass_key="$5" url_key="$6"
          shift 6

          if ! $KUBECTL get secret "$secret" -n "$ns" &>/dev/null; then
            echo "  Skip: $item_name (no secret)"
            return
          fi

          local username="" password="" url="" notes=""
          [ -n "$user_key" ] && username=$(get_secret_value "$ns" "$secret" "$user_key")
          [ -n "$pass_key" ] && password=$(get_secret_value "$ns" "$secret" "$pass_key")
          [ -n "$url_key" ] && url=$(get_secret_value "$ns" "$secret" "$url_key")

          for key in "$@"; do
            local val=$(get_secret_value "$ns" "$secret" "$key")
            if [ -n "$val" ]; then
              notes="''${notes}''${key}=''${val}"$'\n'
            fi
          done

          local uris="[]"
          [ -n "$url" ] && uris=$($JQ -n --arg u "$url" '[{"uri": $u, "match": null}]')

          local existing=$($BW list items --search "$item_name" --organizationid "$ORG_ID" --session "$BW_SESSION" 2>/dev/null || echo "[]")
          local item_id=$(echo "$existing" | $JQ -r ".[] | select(.name == \"$item_name\") | .id" 2>/dev/null || echo "")

          local item_json=$($JQ -n \
            --arg name "$item_name" \
            --arg user "$username" \
            --arg pass "$password" \
            --arg notes "$notes" \
            --arg orgId "$ORG_ID" \
            --argjson uris "$uris" \
            --argjson collIds "[\"$COLLECTION_ID\"]" \
            '{type: 1, name: $name, notes: $notes, login: {username: $user, password: $pass, uris: $uris}, organizationId: $orgId, collectionIds: $collIds}')

          local encoded=$(echo "$item_json" | $BW encode)

          if [ -n "$item_id" ]; then
            $BW edit item "$item_id" "$encoded" --session "$BW_SESSION" --organizationid "$ORG_ID" > /dev/null 2>&1
            echo "  Updated: $item_name"
          else
            $BW create item "$encoded" --session "$BW_SESSION" --organizationid "$ORG_ID" > /dev/null 2>&1
            echo "  Created: $item_name"
          fi
        }

        echo "Syncing credentials to Vaultwarden..."

        # Auth
        sync_service "Authentik" "authentik" "authentik-setup-credentials" \
          "USER" "PASSWORD" "URL"

        # Vaultwarden
        sync_service "Vaultwarden" "vaultwarden" "vaultwarden-admin-credentials" \
          "USER_EMAIL" "USER_PASSWORD" "" "ADMIN_PASSWORD"

        # Arr stack
        sync_service "Sonarr" "media" "sonarr-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"
        sync_service "Sonarr ES" "media" "sonarr-es-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"
        sync_service "Radarr" "media" "radarr-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"
        sync_service "Radarr ES" "media" "radarr-es-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"
        sync_service "Prowlarr" "media" "prowlarr-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"
        sync_service "Lidarr" "media" "lidarr-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"
        sync_service "Bazarr" "media" "bazarr-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"
        sync_service "qBittorrent" "media" "qbittorrent-credentials" \
          "USER" "PASSWORD" "URL"
        sync_service "Bookshelf" "media" "bookshelf-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"

        # Media
        sync_service "Jellyfin" "media" "jellyfin-credentials" \
          "ADMIN_USER" "ADMIN_PASSWORD" ""
        sync_service "Jellyseerr" "media" "jellyseerr-credentials" \
          "" "" "URL" "API_KEY"
        sync_service "Kavita" "media" "kavita-credentials" \
          "ADMIN_USER" "ADMIN_PASSWORD" "URL" "API_KEY"

        # Cloud
        sync_service "Homarr" "homarr" "homarr-credentials" \
          "ADMIN_USER" "ADMIN_PASSWORD" "URL" "API_KEY"
        sync_service "Nextcloud" "nextcloud" "nextcloud-local-credentials" \
          "USER" "PASSWORD" "URL"
        sync_service "Immich" "immich" "immich-local-credentials" \
          "USER" "PASSWORD" "URL" "API_KEY"
        sync_service "Syncthing" "syncthing" "syncthing-credentials" \
          "" "" "URL" "API_KEY" "AUTH" "LDAP_SERVER"

        # Monitoring
        sync_service "Grafana" "monitoring" "grafana-admin-credentials" \
          "ADMIN_USER" "ADMIN_PASSWORD" ""
        sync_service "Uptime Kuma" "uptime-kuma" "uptime-kuma-credentials" \
          "ADMIN_USER" "ADMIN_PASSWORD" "URL"

        $BW logout 2>/dev/null || true

        print_success "Vaultwarden Sync" \
          "All service credentials synced to Vaultwarden" \
          "Organization: Homelab Admin / Collection: Services"

        create_marker "${markerFile}"
      '';
    };
  };
}
