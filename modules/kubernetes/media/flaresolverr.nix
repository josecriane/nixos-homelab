# FlareSolverr - Cloudflare bypass proxy for Prowlarr
# Used by indexers like 1337x and EZTV that have Cloudflare protection
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
  markerFile = "/var/lib/flaresolverr-setup-done";
in
{
  systemd.services.flaresolverr-setup = {
    description = "Setup FlareSolverr for Prowlarr";
    after = [
      "k3s-storage.target"
      "nfs-storage-setup.service"
    ];
    requires = [ "k3s-storage.target" ];
    wantedBy = [ "k3s-media.target" ];
    before = [ "k3s-media.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "flaresolverr-setup" ''
                ${k8s.libShSource}
                setup_preamble "${markerFile}" "FlareSolverr"

                wait_for_k3s
                setup_namespace "${ns}"

                cat <<EOF | $KUBECTL apply -f -
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: flaresolverr
          namespace: ${ns}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: flaresolverr
          template:
            metadata:
              labels:
                app: flaresolverr
            spec:
              containers:
              - name: flaresolverr
                image: ghcr.io/flaresolverr/flaresolverr:v3.3.21
                ports:
                - containerPort: 8191
                env:
                - name: LOG_LEVEL
                  value: "info"
                - name: TZ
                  value: "${serverConfig.timezone}"
                resources:
                  requests:
                    cpu: 50m
                    memory: 128Mi
                  limits:
                    memory: 512Mi
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: flaresolverr
          namespace: ${ns}
        spec:
          selector:
            app: flaresolverr
          ports:
          - port: 8191
            targetPort: 8191
        EOF

                wait_for_deployment "${ns}" "flaresolverr"

                print_success "FlareSolverr" \
                  "Internal URL: http://flaresolverr:8191" \
                  "Configure in Prowlarr > Settings > Indexers > Add > FlareSolverr"

                create_marker "${markerFile}"
      '';
    };
  };
}
