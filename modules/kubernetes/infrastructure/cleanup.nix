# Homelab cleanup map: service toggle -> markers + extra cleanup.
# The implementation lives in nixos-k8s/modules/kubernetes/infrastructure/cleanup.nix;
# this file just populates the k8s.cleanup.serviceMap option.
{ ... }:

{
  k8s.cleanup.serviceMap = {
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
        $KUBECTL delete middlewares.traefik.io forward-auth -n traefik-system --ignore-not-found=true 2>/dev/null || true
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
      namespaces = [ "monitoring" ];
      markers = [
        "monitoring-setup-done"
        "grafana-oidc-setup-done"
        "loki-setup-done"
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
      markers = [ "syncthing-setup-done" ];
    };
    dashboard = {
      namespaces = [ "homer" ];
      markers = [ "homer-setup-done" ];
    };
  };
}
