# Service Manager - homelab glue.
# The binary, image, and deployment live upstream (nixos-k8s apps/service-manager).
# This module wires homelab-specific metadata (group names, protected services,
# hidden namespaces) through the k8s.apps.serviceManager option and adds a
# scale-down reconciler that enforces disabled services, user-paused pods, and
# preferred-node hints after setup scripts re-apply specs.
{
  config,
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  isBootstrap = nodeConfig.bootstrap or false;

  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;

  serviceNamespaces = {
    authentik = [ "authentik" ];
    media = [ "media" ];
    immich = [ "immich" ];
    syncthing = [ "syncthing" ];
    monitoring = [ "monitoring" ];
    vaultwarden = [ "vaultwarden" ];
    nextcloud = [ "nextcloud" ];
    kiwix = [ "kiwix" ];
    openstreetmap = [ "openstreetmap" ];
  };

  disabledNamespaces = lib.concatLists (
    lib.mapAttrsToList (name: namespaces: if enabled name then [ ] else namespaces) serviceNamespaces
  );
in
{
  k8s.apps.serviceManager = {
    hostname = "services";
    groupNames = {
      "kube-system" = "System";
      "traefik-system" = "Infrastructure";
      "cert-manager" = "Infrastructure";
      "metallb-system" = "Infrastructure";
      "service-manager" = "Dashboard";
      "homer" = "Dashboard";
    };
    noStop = [
      "kube-system/*"
      "traefik-system/traefik"
      "cert-manager/*"
      "metallb-system/*"
      "homer/homer"
      "service-manager/service-manager"
    ];
    hide = [ "default" ];
  };

  systemd.services = lib.optionalAttrs isBootstrap {
    service-scaledown =
      let
        setupServices = lib.attrNames (
          lib.filterAttrs (
            n: svc: n != "service-scaledown" && builtins.any (t: lib.hasPrefix "k3s-" t) (svc.wantedBy or [ ])
          ) config.systemd.services
        );
        setupUnits = map (n: "${n}.service") setupServices;
      in
      {
        description = "Scale down disabled services";
        after = [ "k3s-extras.target" ] ++ setupUnits;
        requires = [ "k3s-extras.target" ];
        wantedBy = [ "multi-user.target" ];

        restartTriggers = [
          (builtins.toJSON (serverConfig.services or { }))
        ]
        ++ (map (n: config.systemd.services.${n}.serviceConfig.ExecStart or "") setupServices);

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "service-scaledown" ''
            ${k8s.libShSource}
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

            echo "Scaling down disabled services..."
            ${lib.concatMapStringsSep "\n" (namespace: ''
              echo "Scaling down namespace: ${namespace}"
              for resource in $($KUBECTL get deployments,statefulsets -n ${namespace} -o name 2>/dev/null); do
                $KUBECTL scale "$resource" --replicas=0 -n ${namespace} 2>/dev/null || true
              done
              for ds in $($KUBECTL get daemonsets -n ${namespace} -o name 2>/dev/null); do
                $KUBECTL patch "$ds" -n ${namespace} -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}' 2>/dev/null || true
              done
            '') disabledNamespaces}

            echo "Enforcing user-paused annotation across all namespaces..."
            for kind in deployments statefulsets; do
              $KUBECTL get "$kind" -A -o json 2>/dev/null | $JQ -r \
                '.items[] | select(.metadata.annotations["homelab.k8s/user-paused"] == "true")
                 | "\(.metadata.namespace) \(.metadata.name)"' | \
              while read -r ns name; do
                [ -z "$ns" ] && continue
                echo "Preserving paused: $kind $ns/$name"
                $KUBECTL scale "$kind/$name" -n "$ns" --replicas=0 2>/dev/null || true
              done
            done
            $KUBECTL get daemonsets -A -o json 2>/dev/null | $JQ -r \
              '.items[] | select(.metadata.annotations["homelab.k8s/user-paused"] == "true")
               | "\(.metadata.namespace) \(.metadata.name)"' | \
            while read -r ns name; do
              [ -z "$ns" ] && continue
              echo "Preserving paused: daemonset $ns/$name"
              $KUBECTL patch "daemonset/$name" -n "$ns" \
                -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}' 2>/dev/null || true
            done

            echo "Enforcing preferred-node annotation..."
            for kind in deployments statefulsets; do
              $KUBECTL get "$kind" -A -o json 2>/dev/null | $JQ -r \
                '.items[] | select(.metadata.annotations["homelab.k8s/preferred-node"] != null and .metadata.annotations["homelab.k8s/preferred-node"] != "")
                 | "\(.metadata.namespace) \(.metadata.name) \(.metadata.annotations["homelab.k8s/preferred-node"])"' | \
              while read -r ns name node; do
                [ -z "$ns" ] && continue
                echo "Pinning preference: $kind $ns/$name -> $node"
                patch=$($JQ -nc --arg node "$node" '{spec:{template:{spec:{affinity:{nodeAffinity:{preferredDuringSchedulingIgnoredDuringExecution:[{weight:100,preference:{matchExpressions:[{key:"kubernetes.io/hostname",operator:"In",values:[$node]}]}}]}}}}}}')
                $KUBECTL patch "$kind/$name" -n "$ns" --type=merge -p "$patch" 2>/dev/null || true
              done
            done

            echo "Scale-down complete"
          '';
        };
      };
  };
}
