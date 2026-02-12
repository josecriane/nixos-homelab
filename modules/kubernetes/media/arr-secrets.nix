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
  markerFile = "/var/lib/arr-secrets-setup-done";
in
{
  systemd.services.arr-secrets-setup = {
    description = "Generate stable API keys for arr-stack services";
    after = [
      "k3s-core.target"
      "nfs-storage-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [ "nfs-storage-setup.service" ];
    # TIER 4: Media (must run BEFORE arr-stack-setup)
    wantedBy = [ "k3s-media.target" ];
    before = [
      "k3s-media.target"
      "arr-stack-setup.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "arr-secrets-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "arr-stack secrets"

        wait_for_k3s
        setup_namespace "${ns}"

        # Create a K8s Secret with a stable API key for an arr service.
        # If the Secret already exists, leave it alone.
        ensure_api_key() {
          local service=$1
          local secret_name="''${service}-api-key"

          if $KUBECTL get secret "$secret_name" -n ${ns} &>/dev/null; then
            echo "  $service: API key secret already exists"
          else
            API_KEY=$($OPENSSL rand -hex 16)
            $KUBECTL create secret generic "$secret_name" \
              --from-literal=api-key="$API_KEY" \
              -n ${ns}
            echo "  $service: API key secret created"
          fi
        }

        echo "Generating stable API keys for arr services..."
        ensure_api_key prowlarr
        ensure_api_key sonarr
        ensure_api_key sonarr-es
        ensure_api_key radarr
        ensure_api_key radarr-es
        ensure_api_key lidarr
        ensure_api_key bookshelf

        print_success "arr-stack secrets" \
          "API keys stored in Kubernetes Secrets (namespace: media)" \
          "Pods will use init containers to pre-seed config.xml"

        create_marker "${markerFile}"
      '';
    };
  };
}
