# Homelab cleanup map: service toggle -> extra cleanup when disabled.
# The implementation lives in nixos-k8s/modules/kubernetes/infrastructure/cleanup.nix;
# this file just populates the k8s.cleanup.serviceMap option.
{ ... }:

{
  k8s.cleanup.serviceMap = {
    authentik.extraCleanup = ''
      echo "Cleaning authentik cross-namespace resources..."
      $KUBECTL delete middlewares.traefik.io forward-auth -n traefik-system --ignore-not-found=true 2>/dev/null || true
      $KUBECTL delete configmap coredns-custom -n kube-system --ignore-not-found=true 2>/dev/null || true
    '';
  };
}
