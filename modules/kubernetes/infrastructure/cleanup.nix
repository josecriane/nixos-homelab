# Automatic cleanup of disabled K8s services
# Always imported - generates cleanup commands only for disabled services
# PVCs are preserved to protect user data
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;

  # Service toggle -> namespaces and marker files to clean
  serviceMap = {
    authentik = {
      namespaces = [ "authentik" ];
      markers = [
        "authentik-setup-done"
        "authentik-sso-setup-done"
        "authentik-ldap-done"
        "authentik-nas-apps-done"
      ];
      extraCleanup = ''
        echo "Cleaning authentik cross-namespace resources..."
        $KUBECTL delete middlewares.traefik.io authentik-forward-auth -n traefik-system --ignore-not-found=true 2>/dev/null || true
        $KUBECTL delete configmap coredns-custom -n kube-system --ignore-not-found=true 2>/dev/null || true
      '';
    };
    vaultwarden = {
      namespaces = [ "vaultwarden" ];
      markers = [
        "vaultwarden-setup-done"
        "vaultwarden-sso-setup-done"
        "vaultwarden-admin-setup-done"
      ];
    };
    nextcloud = {
      namespaces = [ "nextcloud" ];
      markers = [
        "nextcloud-setup-done"
        "nextcloud-oidc-setup-done"
      ];
    };
    monitoring = {
      namespaces = [
        "monitoring"
        "uptime-kuma"
      ];
      markers = [
        "monitoring-setup-done"
        "grafana-oidc-setup-done"
        "loki-setup-done"
        "uptime-kuma-setup-done"
      ];
    };
    media = {
      namespaces = [ "media" ];
      markers = [
        "arr-stack-setup-done"
        "arr-secrets-setup-done"
        "arr-credentials-setup-done"
        "arr-download-clients-setup-done"
        "arr-prowlarr-sync-setup-done"
        "arr-root-folders-setup-done"
        "arr-naming-setup-done"
        "lidarr-config-setup-done"
        "bazarr-config-setup-done"
        "jellyfin-integration-setup-done"
        "jellyfin-setup-done"
        "jellyseerr-setup-done"
        "jellyseerr-oidc-config-done"
        "bazarr-setup-done"
        "lidarr-setup-done"
        "bookshelf-setup-done"
        "flaresolverr-setup-done"
        "recyclarr-setup-done"
        "kavita-setup-done"
        "nas-integration-setup-done"
      ];
    };
    immich = {
      namespaces = [ "immich" ];
      markers = [
        "immich-setup-done"
        "immich-oauth-setup-done"
      ];
    };
    syncthing = {
      namespaces = [ "syncthing" ];
      markers = [
        "syncthing-setup-done"
      ];
    };
    dashboard = {
      namespaces = [ "homarr" ];
      markers = [
        "homarr-setup-done"
        "homarr-config-done"
      ];
    };
  };

  disabledServices = lib.filterAttrs (name: _: !(enabled name)) serviceMap;
  hasDisabled = (builtins.length (builtins.attrNames disabledServices)) > 0;

  cleanupCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: cfg:
      let
        nsCleanups = lib.concatMapStringsSep "\n" (ns: ''cleanup_namespace "${ns}"'') cfg.namespaces;

        markerCleanups = lib.concatMapStringsSep "\n" (m: ''rm -f "/var/lib/${m}"'') cfg.markers;

        extra = cfg.extraCleanup or "";
      in
      ''
        echo ""
        echo "=== Cleaning disabled service: ${name} ==="
        ${nsCleanups}
        ${extra}
        ${markerCleanups}
      ''
    ) disabledServices
  );

in
{
  systemd.services.k8s-cleanup = lib.mkIf hasDisabled {
    description = "Cleanup disabled K8s services";
    after = [ "k3s-infrastructure.target" ];
    requires = [ "k3s-infrastructure.target" ];
    wantedBy = [ "k3s-storage.target" ];
    before = [ "k3s-storage.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "k8s-cleanup" ''
        ${k8s.libShSource}
        set -e
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        echo "Starting cleanup of disabled services..."
        wait_for_k3s

        ${cleanupCommands}

        echo ""
        echo "Cleanup of disabled services completed"
      '';
    };
  };
}
