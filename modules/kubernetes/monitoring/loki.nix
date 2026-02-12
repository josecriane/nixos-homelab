{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "monitoring";
  markerFile = "/var/lib/loki-setup-done";
in
{
  systemd.services.loki-setup = {
    description = "Setup Loki log aggregation";
    after = [
      "k3s-storage.target"
      "monitoring-setup.service"
    ];
    requires = [ "k3s-storage.target" ];
    wants = [ "monitoring-setup.service" ];
    # TIER 3: Core
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "loki-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Loki"

        wait_for_k3s

        helm_repo_add "grafana" "https://grafana.github.io/helm-charts"

        # Install Loki (SingleBinary mode - suitable for single-node)
        $HELM upgrade --install loki grafana/loki \
          --namespace ${ns} \
          --set deploymentMode=SingleBinary \
          --set loki.auth_enabled=false \
          --set loki.commonConfig.replication_factor=1 \
          --set loki.storage.type=filesystem \
          --set loki.schemaConfig.configs[0].from=2024-01-01 \
          --set loki.schemaConfig.configs[0].store=tsdb \
          --set loki.schemaConfig.configs[0].object_store=filesystem \
          --set loki.schemaConfig.configs[0].schema=v13 \
          --set loki.schemaConfig.configs[0].index.prefix=index_ \
          --set loki.schemaConfig.configs[0].index.period=24h \
          --set singleBinary.replicas=1 \
          --set singleBinary.persistence.enabled=true \
          --set singleBinary.persistence.size=10Gi \
          --set "singleBinary.resources.requests.cpu=50m" \
          --set "singleBinary.resources.requests.memory=128Mi" \
          --set "singleBinary.resources.limits.memory=1Gi" \
          --set read.replicas=0 \
          --set write.replicas=0 \
          --set backend.replicas=0 \
          --set gateway.enabled=false \
          --set chunksCache.enabled=false \
          --set resultsCache.enabled=false \
          --wait \
          --timeout 5m

        # Install Promtail
        $HELM upgrade --install promtail grafana/promtail \
          --namespace ${ns} \
          --set "config.clients[0].url=http://loki:3100/loki/api/v1/push" \
          --set "resources.requests.cpu=25m" \
          --set "resources.requests.memory=64Mi" \
          --set "resources.limits.memory=256Mi" \
          --wait \
          --timeout 5m

        wait_for_pod "${ns}" "app.kubernetes.io/name=loki" 120

        print_success "Loki" \
          "View logs at: Grafana > Explore > Loki"

        create_marker "${markerFile}"
      '';
    };
  };
}
