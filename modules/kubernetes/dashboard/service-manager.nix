# Service Manager - Start/stop K8s services from the browser
{
  config,
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "service-manager";
  markerFile = "/var/lib/service-manager-setup-done";

  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;

  # Config overrides - the Go binary auto-discovers ALL namespaces and deployments.
  # This config only provides: custom group names, noStop lists, and hidden namespaces.
  serviceManagerConfig = {
    # Map namespace -> display group name (namespaces not listed here use Title Case of namespace name)
    groupNames = {
      "kube-system" = "System";
      "traefik-system" = "Infrastructure";
      "cert-manager" = "Infrastructure";
      "metallb-system" = "Infrastructure";
      "service-manager" = "Dashboard";
      "homer" = "Dashboard";
    };
    # Deployments that cannot be stopped (only restarted)
    noStop = [
      "kube-system/*"
      "traefik-system/traefik"
      "cert-manager/*"
      "metallb-system/*"
      "homer/homer"
      "service-manager/service-manager"
    ];
    # Namespaces to hide entirely
    hide = [
      "default"
    ];
  };

  servicesJson = builtins.toJSON serviceManagerConfig;

  # Map config.nix service names to K8s namespaces for scale-down
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

  # Namespaces that should be scaled to 0 (service disabled in config)
  disabledNamespaces = lib.concatLists (
    lib.mapAttrsToList (name: namespaces: if enabled name then [ ] else namespaces) serviceNamespaces
  );

  # Build Go binary
  serviceManagerBin = pkgs.buildGoModule {
    pname = "service-manager";
    version = "1.0.0";
    src = ./service-manager;
    vendorHash = null;
  };

  # Build container image
  serviceManagerImage = pkgs.dockerTools.buildImage {
    name = "service-manager";
    tag = "latest";
    copyToRoot = [ serviceManagerBin ];
    config = {
      Cmd = [ "${serviceManagerBin}/bin/service-manager" ];
      ExposedPorts = {
        "8080/tcp" = { };
      };
    };
  };
in
{
  systemd.services = {
    service-manager-setup = {
      description = "Setup Service Manager";
      after = [ "k3s-storage.target" ];
      requires = [ "k3s-storage.target" ];
      wantedBy = [ "k3s-core.target" ];
      before = [ "k3s-core.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "service-manager-setup" ''
                  ${k8s.libShSource}
                  IMAGE_HASH="${serviceManagerImage}"
                  setup_preamble_hash "${markerFile}" "Service Manager" "$IMAGE_HASH"

                  wait_for_k3s
                  wait_for_traefik
                  wait_for_certificate
                  ensure_namespace "${ns}"

                  # Import container image
                  echo "Importing Service Manager image..."
                  ${pkgs.k3s}/bin/k3s ctr images import ${serviceManagerImage}

                  # ServiceAccount + RBAC
                  cat <<'EOF' | $KUBECTL apply -f -
          apiVersion: v1
          kind: ServiceAccount
          metadata:
            name: service-manager
            namespace: ${ns}
          ---
          apiVersion: rbac.authorization.k8s.io/v1
          kind: ClusterRole
          metadata:
            name: service-manager
          rules:
            - apiGroups: ["apps"]
              resources: ["deployments", "statefulsets", "daemonsets"]
              verbs: ["get", "list", "patch"]
            - apiGroups: ["apps"]
              resources: ["deployments/scale", "statefulsets/scale"]
              verbs: ["get", "update", "patch"]
            - apiGroups: ["metrics.k8s.io"]
              resources: ["pods"]
              verbs: ["get", "list"]
            - apiGroups: [""]
              resources: ["nodes"]
              verbs: ["get", "list"]
            - apiGroups: ["metrics.k8s.io"]
              resources: ["nodes"]
              verbs: ["get", "list"]
          ---
          apiVersion: rbac.authorization.k8s.io/v1
          kind: ClusterRoleBinding
          metadata:
            name: service-manager
          roleRef:
            apiGroup: rbac.authorization.k8s.io
            kind: ClusterRole
            name: service-manager
          subjects:
            - kind: ServiceAccount
              name: service-manager
              namespace: ${ns}
          EOF

                  # ConfigMap with service whitelist
                  $KUBECTL create configmap service-manager-config -n ${ns} \
                    --from-literal=services.json='${servicesJson}' \
                    --dry-run=client -o yaml | $KUBECTL apply -f -

                  # Deployment
                  cat <<'EOF' | $KUBECTL apply -f -
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: service-manager
            namespace: ${ns}
          spec:
            replicas: 1
            selector:
              matchLabels:
                app: service-manager
            template:
              metadata:
                labels:
                  app: service-manager
              spec:
                serviceAccountName: service-manager
                containers:
                - name: service-manager
                  image: docker.io/library/service-manager:latest
                  imagePullPolicy: Never
                  ports:
                  - containerPort: 8080
                  resources:
                    requests:
                      cpu: 5m
                      memory: 16Mi
                    limits:
                      memory: 64Mi
                  volumeMounts:
                  - name: config
                    mountPath: /config
                volumes:
                - name: config
                  configMap:
                    name: service-manager-config
          ---
          apiVersion: v1
          kind: Service
          metadata:
            name: service-manager
            namespace: ${ns}
          spec:
            selector:
              app: service-manager
            ports:
            - port: 8080
              targetPort: 8080
          EOF

                  wait_for_deployment "${ns}" "service-manager" 120

                  # Force rollout to pick up new image (same :latest tag)
                  echo "Rolling out service-manager to pick up new image..."
                  $KUBECTL rollout restart deployment/service-manager -n ${ns}
                  $KUBECTL rollout status deployment/service-manager -n ${ns} --timeout=120s

                  # IngressRoute: UI + read API (no auth)
                  create_ingress_route "service-manager" "${ns}" "$(hostname services)" "service-manager" "8080"

                  print_success "Service Manager" \
                    "URL: https://$(hostname services)"

                  create_marker "${markerFile}" "$IMAGE_HASH"
        '';
      };
    };
  }
  // lib.optionalAttrs (disabledNamespaces != [ ]) {
    service-scaledown =
      let
        # Setup services that provision k8s workloads; scaledown must run after them
        # so helm/kubectl apply doesn't resurrect replicas after we've scaled to 0.
        setupServices = lib.attrNames (
          lib.filterAttrs (
            n: svc:
            n != "service-scaledown"
            && builtins.any (t: lib.hasPrefix "k3s-" t) (svc.wantedBy or [ ])
          ) config.systemd.services
        );
        setupUnits = map (n: "${n}.service") setupServices;
      in
      {
        description = "Scale down disabled services";
        after = [ "k3s-extras.target" ] ++ setupUnits;
        requires = [ "k3s-extras.target" ];
        wantedBy = [ "multi-user.target" ];

        # Re-run on every rebuild that touches a setup script or toggles a flag
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
          # Deployments / StatefulSets: scale to 0 if user-paused
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
          # DaemonSets: pin to non-existing node selector if user-paused
          $KUBECTL get daemonsets -A -o json 2>/dev/null | $JQ -r \
            '.items[] | select(.metadata.annotations["homelab.k8s/user-paused"] == "true")
             | "\(.metadata.namespace) \(.metadata.name)"' | \
          while read -r ns name; do
            [ -z "$ns" ] && continue
            echo "Preserving paused: daemonset $ns/$name"
            $KUBECTL patch "daemonset/$name" -n "$ns" \
              -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}' 2>/dev/null || true
          done

          echo "Scale-down complete"
        '';
      };
    };
  };
}
