{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

{
  # Service to install and configure MetalLB automatically
  systemd.services.metallb-setup = {
    description = "Setup MetalLB load balancer";
    after = [
      "k3s.service"
      "k3s-cni-bridge-fixer.service"
    ];
    wants = [
      "k3s.service"
      "k3s-cni-bridge-fixer.service"
    ];
    # TIER 1: Infraestructura
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "metallb-setup" ''
        set -e

        # Marker file to run only once
        MARKER_FILE="/var/lib/metallb-setup-done"

        if [ -f "$MARKER_FILE" ]; then
          echo "MetalLB already installed (marker file exists)"
          exit 0
        fi

        echo "Waiting for K3s to be fully ready..."
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

        # Wait for Flannel to generate subnet.env (needed for pods)
        echo "Waiting for Flannel subnet.env..."
        for i in $(seq 1 60); do
          if [ -f /run/flannel/subnet.env ]; then
            echo "Flannel subnet.env available"
            break
          fi
          echo "Waiting for Flannel subnet.env... ($i/60)"
          sleep 5
        done
        if [ ! -f /run/flannel/subnet.env ]; then
          echo "ERROR: Flannel subnet.env does not exist after 5 minutes"
          exit 1
        fi

        # Wait for cni0 bridge to be UP (k3s-cni-bridge-fixer manages this)
        echo "Waiting for cni0 bridge to be UP..."
        for i in $(seq 1 60); do
          if ${pkgs.iproute2}/bin/ip link show cni0 2>/dev/null | grep -q "state UP"; then
            echo "cni0 bridge is UP"
            break
          fi
          echo "Waiting for cni0 bridge... ($i/60)"
          sleep 5
        done

        # Verify CoreDNS works (real test that pod networking works)
        echo "Waiting for CoreDNS to be Ready..."
        ${pkgs.kubectl}/bin/kubectl wait --namespace kube-system \
          --for=condition=ready pod \
          --selector=k8s-app=kube-dns \
          --timeout=300s || true

        echo "Installing MetalLB with Helm..."

        # Add MetalLB repository
        ${pkgs.kubernetes-helm}/bin/helm repo add metallb https://metallb.github.io/metallb || true
        ${pkgs.kubernetes-helm}/bin/helm repo update

        # Create memberlist secret for speaker pods (required since MetalLB v0.14+)
        ${pkgs.kubectl}/bin/kubectl create namespace metallb-system --dry-run=client -o yaml | ${pkgs.kubectl}/bin/kubectl apply -f -
        ${pkgs.kubectl}/bin/kubectl create secret generic -n metallb-system metallb-memberlist \
          --from-literal=secretkey="$(${pkgs.openssl}/bin/openssl rand -base64 128)" \
          --dry-run=client -o yaml | ${pkgs.kubectl}/bin/kubectl apply -f -

        # Install MetalLB
        ${pkgs.kubernetes-helm}/bin/helm upgrade --install metallb metallb/metallb \
          --namespace metallb-system \
          --create-namespace \
          --wait \
          --timeout 5m

        echo "Waiting for MetalLB pods to be ready..."
        ${pkgs.kubectl}/bin/kubectl wait --namespace metallb-system \
          --for=condition=ready pod \
          --selector=app.kubernetes.io/name=metallb \
          --timeout=300s

        echo "Applying MetalLB configuration (IPAddressPool and L2Advertisement)..."

        # Create IPAddressPool
        cat <<EOF | ${pkgs.kubectl}/bin/kubectl apply -f -
        apiVersion: metallb.io/v1beta1
        kind: IPAddressPool
        metadata:
          name: default-pool
          namespace: metallb-system
        spec:
          addresses:
          - ${serverConfig.metallbPoolStart}-${serverConfig.metallbPoolEnd}
        EOF

        # Create L2Advertisement
        cat <<EOF | ${pkgs.kubectl}/bin/kubectl apply -f -
        apiVersion: metallb.io/v1beta1
        kind: L2Advertisement
        metadata:
          name: default-l2
          namespace: metallb-system
        spec:
          ipAddressPools:
          - default-pool
        EOF

        echo "MetalLB installed and configured successfully"
        echo "IP pool: ${serverConfig.metallbPoolStart}-${serverConfig.metallbPoolEnd}"

        # Create marker file
        touch "$MARKER_FILE"
        echo "Installation completed"
      '';
    };
  };
}
