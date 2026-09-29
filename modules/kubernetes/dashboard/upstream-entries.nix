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

  ping = namespace: name: { inherit namespace name; };
in
{
  dashboard.items = {
    traefik = {
      group = "infrastructure";
      title = "Traefik";
      icon = "fas fa-route";
      subtitle = "Ingress Controller";
      url = "https://${k8s.hostname "traefik"}";
      sort = 10;
    };
    registry-ui = {
      group = "infrastructure";
      title = "Registry";
      icon = "fas fa-box";
      subtitle = "Container Images";
      url = "https://${k8s.hostname "registry-ui"}";
      sort = 45;
    };
  }
  // lib.optionalAttrs longhornEnabled {
    longhorn = {
      group = "infrastructure";
      title = "Longhorn";
      icon = "fas fa-hdd";
      subtitle = "Distributed Storage";
      url = "https://${k8s.hostname longhorn.ingress.host}";
      sort = 40;
    };
  }
  // lib.optionalAttrs (enabled "monitoring") {
    grafana = {
      group = "monitoring";
      title = "Grafana";
      icon = "fas fa-chart-area";
      subtitle = "Dashboards";
      url = "https://${k8s.hostname "grafana"}";
      ping = ping "monitoring" "grafana";
      sort = 10;
    };
    prometheus = {
      group = "monitoring";
      title = "Prometheus";
      icon = "fas fa-database";
      subtitle = "Metrics";
      url = "https://${k8s.hostname "prometheus"}";
      ping = ping "monitoring" "prometheus-server";
      sort = 20;
    };
    alertmanager = {
      group = "monitoring";
      title = "Alertmanager";
      icon = "fas fa-bell";
      subtitle = "Alerts";
      url = "https://${k8s.hostname "alertmanager"}";
      ping = ping "monitoring" "alertmanager";
      sort = 30;
    };
  };
}
