# Service Manager - Start/stop K8s services from the browser
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
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
  systemd.services.service-manager-setup = {
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
                setup_preamble "${markerFile}" "Service Manager"

                wait_for_k3s
                wait_for_traefik
                wait_for_certificate
                setup_namespace "${ns}"

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
            resources: ["deployments"]
            verbs: ["get", "list", "patch"]
          - apiGroups: ["apps"]
            resources: ["deployments/scale"]
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

                # IngressRoute: UI + read API (no auth)
                create_ingress_route "service-manager" "${ns}" "$(hostname services)" "service-manager" "8080"

                print_success "Service Manager" \
                  "URL: https://$(hostname services)"

                create_marker "${markerFile}"
      '';
    };
  };
}
