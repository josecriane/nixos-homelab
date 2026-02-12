{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

{
  # Service to install and configure Traefik automatically
  systemd.services.traefik-setup = {
    description = "Setup Traefik ingress controller";
    after = [
      "k3s.service"
      "metallb-setup.service"
    ];
    wants = [
      "k3s.service"
      "metallb-setup.service"
    ];
    # TIER 1: Infrastructure
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "traefik-setup" ''
                set -e

                # Marker file to run only once
                MARKER_FILE="/var/lib/traefik-setup-done"

                if [ -f "$MARKER_FILE" ]; then
                  echo "Traefik already installed (marker file exists)"
                  exit 0
                fi

                echo "Waiting for K3s and MetalLB to be fully ready..."
                export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

                # Wait for k3s to be ready (max 5 minutes)
                for i in $(seq 1 60); do
                  if ${pkgs.kubectl}/bin/kubectl get nodes &>/dev/null; then
                    echo "K3s is ready"
                    break
                  fi
                  echo "Waiting for K3s... ($i/60)"
                  sleep 5
                done

                # Verify that k3s is actually ready
                if ! ${pkgs.kubectl}/bin/kubectl get nodes &>/dev/null; then
                  echo "ERROR: K3s not available after 5 minutes"
                  exit 1
                fi

                echo "Waiting for node to be Ready (Flannel CNI)..."
                if ! ${pkgs.kubectl}/bin/kubectl wait --for=condition=Ready node --all --timeout=300s; then
                  echo "ERROR: Node did not reach Ready state in 5 minutes"
                  exit 1
                fi
                echo "K3s node is Ready (Flannel CNI initialized)"

                # Wait for MetalLB to be ready (max 3 minutes)
                echo "Waiting for MetalLB to be ready..."
                for i in $(seq 1 36); do
                  if ${pkgs.kubectl}/bin/kubectl get namespace metallb-system &>/dev/null && \
                     ${pkgs.kubectl}/bin/kubectl get ipaddresspool -n metallb-system default-pool &>/dev/null; then
                    echo "MetalLB is ready"
                    break
                  fi
                  echo "Waiting for MetalLB... ($i/36)"
                  sleep 5
                done

                # Verify that MetalLB is actually ready
                if ! ${pkgs.kubectl}/bin/kubectl get ipaddresspool -n metallb-system default-pool &>/dev/null; then
                  echo "ERROR: MetalLB not available after 3 minutes"
                  exit 1
                fi

                echo "Installing Traefik with Helm..."

                # Add Traefik repository
                ${pkgs.kubernetes-helm}/bin/helm repo add traefik https://traefik.github.io/charts || true
                ${pkgs.kubernetes-helm}/bin/helm repo update

                # Create namespace
                ${pkgs.kubectl}/bin/kubectl create namespace traefik-system --dry-run=client -o yaml | \
                  ${pkgs.kubectl}/bin/kubectl apply -f -

                # Install Traefik with custom configuration
                ${pkgs.kubernetes-helm}/bin/helm upgrade --install traefik traefik/traefik \
                  --namespace traefik-system \
                  --set service.type=LoadBalancer \
                  --set service.spec.loadBalancerIP=${serverConfig.traefikIP} \
                  --set ports.web.port=80 \
                  --set ports.web.exposedPort=80 \
                  --set ports.websecure.port=443 \
                  --set ports.websecure.exposedPort=443 \
                  --set ingressClass.enabled=true \
                  --set ingressClass.isDefaultClass=true \
                  --set ingressRoute.dashboard.enabled=false \
                  --set logs.general.level=INFO \
                  --set logs.access.enabled=true \
                  --set providers.kubernetesCRD.enabled=true \
                  --set providers.kubernetesIngress.enabled=true \
                  --set additionalArguments[0]="--certificatesresolvers.default.acme.email=${serverConfig.acmeEmail}" \
                  --set additionalArguments[1]="--certificatesresolvers.default.acme.storage=/data/acme.json" \
                  --set additionalArguments[2]="--certificatesresolvers.default.acme.tlschallenge=true" \
                  --set additionalArguments[3]="--providers.kubernetescrd.allowCrossNamespace=true" \
                  --set persistence.enabled=true \
                  --set persistence.size=1Gi \
                  --wait \
                  --timeout 5m

                echo "Waiting for Traefik pod to be ready..."
                ${pkgs.kubectl}/bin/kubectl wait --namespace traefik-system \
                  --for=condition=ready pod \
                  --selector=app.kubernetes.io/name=traefik \
                  --timeout=300s

                echo "Waiting for Traefik to get LoadBalancer IP..."
                for i in $(seq 1 30); do
                  TRAEFIK_IP=$(${pkgs.kubectl}/bin/kubectl get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
                  if [ "$TRAEFIK_IP" = "${serverConfig.traefikIP}" ]; then
                    echo "Traefik got IP: $TRAEFIK_IP"
                    break
                  fi
                  echo "Waiting for LoadBalancer IP... ($i/30) (current: $TRAEFIK_IP)"
                  sleep 2
                done

                # Verify the final IP
                FINAL_IP=$(${pkgs.kubectl}/bin/kubectl get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

                # Create IngressRoute for Traefik dashboard
                echo "Creating IngressRoute for Traefik dashboard..."
                cat <<EOF | ${pkgs.kubectl}/bin/kubectl apply -f -
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: traefik-dashboard
          namespace: traefik-system
        spec:
          entryPoints:
            - websecure
          routes:
            - match: Host(\`traefik.${serverConfig.subdomain}.${serverConfig.domain}\`)
              kind: Rule
              middlewares:
                - name: authentik-forward-auth
                  namespace: traefik-system
              services:
                - kind: TraefikService
                  name: api@internal
          tls:
            secretName: wildcard-${serverConfig.subdomain}-${serverConfig.domain}-tls
        EOF

                echo ""
                echo "========================================="
                echo "Traefik installed and configured successfully"
                echo "LoadBalancer IP: $FINAL_IP"
                echo "Ports: 80 (HTTP), 443 (HTTPS)"
                echo "Dashboard: https://traefik.${serverConfig.subdomain}.${serverConfig.domain}/dashboard/"
                echo "IngressClass: traefik (default)"
                echo "========================================="
                echo ""

                # Create marker file
                touch "$MARKER_FILE"
                echo "Installation completed"
      '';
    };
  };
}
