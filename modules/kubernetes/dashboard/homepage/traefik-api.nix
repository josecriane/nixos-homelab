{
  k8s,
  pkgs,
  ...
}:

let
  ns = "traefik-system";
  host = k8s.hostname "traefik-api";
  markerFile = "/var/lib/traefik-api-setup-done";
in
{
  systemd.services.traefik-api-setup = {
    description = "Expose the read-only Traefik API behind basic auth for the dashboard";
    after = [
      "k3s.service"
      "traefik-setup.service"
    ];
    wants = [ "traefik-setup.service" ];
    wantedBy = [ "k3s-apps.target" ];
    before = [ "k3s-apps.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "traefik-api-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Traefik API"
        wait_for_k3s
        wait_for_resource middleware "${ns}" hsts-headers 300

        if ! $KUBECTL -n ${ns} get secret traefik-api-credentials >/dev/null 2>&1; then
          store_credentials "${ns}" "traefik-api-credentials" \
            "USER=homepage" \
            "PASSWORD=$(generate_password 24)"
        fi
        USER=$(get_secret_value "${ns}" "traefik-api-credentials" "USER")
        PASSWORD=$(get_secret_value "${ns}" "traefik-api-credentials" "PASSWORD")
        HASH=$($OPENSSL passwd -apr1 "$PASSWORD")
        store_credentials "${ns}" "traefik-api-auth" "users=$USER:$HASH"

        cat <<'MWEOF' | $KUBECTL apply -f -
        apiVersion: traefik.io/v1alpha1
        kind: Middleware
        metadata:
          name: traefik-api-auth
          namespace: ${ns}
        spec:
          basicAuth:
            secret: traefik-api-auth
        MWEOF

        cat <<'RTEOF' | $KUBECTL apply --server-side --force-conflicts -f -
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: traefik-api
          namespace: ${ns}
        spec:
          entryPoints:
            - websecure
          routes:
            - kind: Rule
              match: Host(`${host}`) && PathPrefix(`/api/`)
              middlewares:
                - name: hsts-headers
                - name: traefik-api-auth
              services:
                - kind: TraefikService
                  name: api@internal
          tls:
            store:
              name: default
              namespace: ${ns}
        RTEOF

        print_success "Traefik API" "URL: https://${host}/api/ (basic auth, secret traefik-api-credentials)"
        create_marker "${markerFile}"
      '';
    };
  };
}
