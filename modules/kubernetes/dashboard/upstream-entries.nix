# Dashboard entries for services whose module lives in nixos-k8s, which does not
# know about `dashboard`. They are declared here until the option moves
# down a layer. Everything installed by this repo registers its own entry from
# the module that installs it.
{
  k8s,
  lib,
  serverConfig,
  ...
}:

let
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;

  longhorn = serverConfig.storage.longhorn;
  longhornEnabled = (longhorn.enable or false) && ((longhorn.ingress or null) != null);

  monitoringSecret = key: {
    namespace = "monitoring";
    secret = "grafana-admin-credentials";
    inherit key;
  };
  traefikApiSecret = key: {
    namespace = "traefik-system";
    secret = "traefik-api-credentials";
    inherit key;
  };
in
{
  dashboard.items = {
    traefik = {
      group = "infrastructure";
      title = "Traefik";
      icon = "sh-traefik";
      subtitle = "Ingress Controller";
      url = "https://${k8s.hostname "traefik"}";
      workload = {
        namespace = "traefik-system";
        name = "traefik";
      };
      widget = {
        type = "traefik";
        url = "https://${k8s.hostname "traefik-api"}";
        secrets = {
          username = traefikApiSecret "USER";
          password = traefikApiSecret "PASSWORD";
        };
      };
      sort = 10;
    };
    registry-ui = {
      group = "infrastructure";
      title = "Registry";
      icon = "mdi-package-variant";
      subtitle = "Container Images";
      url = "https://${k8s.hostname "registry-ui"}";
      workload = {
        namespace = "container-registry";
        name = "docker-registry-ui-docker-registry-ui-user-interface";
        selector = "app.kubernetes.io/name=docker-registry-ui";
      };
      sort = 45;
    };
  }
  // lib.optionalAttrs longhornEnabled {
    longhorn = {
      group = "infrastructure";
      title = "Longhorn";
      icon = "mdi-harddisk";
      subtitle = "Distributed Storage";
      url = "https://${k8s.hostname longhorn.ingress.host}";
      workload = {
        namespace = "longhorn-system";
        name = "longhorn-ui";
        selector = "app=longhorn-ui";
      };
      sort = 40;
    };
  }
  // lib.optionalAttrs (enabled "monitoring") {
    grafana = {
      group = "monitoring";
      title = "Grafana";
      icon = "sh-grafana";
      subtitle = "Dashboards";
      url = "https://${k8s.hostname "grafana"}";
      workload = {
        namespace = "monitoring";
        name = "kube-prometheus-stack-grafana";
        selector = "app.kubernetes.io/name=grafana";
      };
      widget = {
        type = "grafana";
        url = "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80";
        secrets = {
          username = monitoringSecret "admin-user";
          password = monitoringSecret "admin-password";
        };
        options.version = 2;
      };
      sort = 10;
    };
    prometheus = {
      group = "monitoring";
      title = "Prometheus";
      icon = "sh-prometheus";
      subtitle = "Metrics";
      url = "https://${k8s.hostname "prometheus"}";
      workload = {
        namespace = "monitoring";
        name = "prometheus-kube-prometheus-stack-prometheus";
        selector = "app.kubernetes.io/name=prometheus";
      };
      widget = {
        type = "prometheus";
        url = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090";
      };
      sort = 20;
    };
    alertmanager = {
      group = "monitoring";
      title = "Alertmanager";
      icon = "mdi-bell-ring";
      subtitle = "Alerts";
      url = "https://${k8s.hostname "alertmanager"}";
      workload = {
        namespace = "monitoring";
        name = "alertmanager-kube-prometheus-stack-alertmanager";
        selector = "app.kubernetes.io/name=alertmanager";
      };
      sort = 30;
    };
  };
}
