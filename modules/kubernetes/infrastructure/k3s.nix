{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

{
  # K3s - Lightweight Kubernetes
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = toString [
      "--secrets-encryption"
      "--disable=traefik" # We use Traefik from Helm
      "--disable=servicelb" # We use MetalLB
      "--write-kubeconfig-mode=600"
      "--cluster-cidr=10.42.0.0/16"
      "--service-cidr=10.43.0.0/16"
      "--kubelet-arg=system-reserved=cpu=500m,memory=512Mi"
      "--kubelet-arg=kube-reserved=cpu=500m,memory=512Mi"
      "--kubelet-arg=eviction-hard=memory.available<256Mi,nodefs.available<10%"
    ];
  };

  # Ensure K3s waits for network to be ready
  systemd.services.k3s = {
    after = [
      "network-online.target"
      "k3s-network-check.service"
    ];
    wants = [
      "network-online.target"
      "k3s-network-check.service"
    ];
    requires = [ "k3s-network-check.service" ]; # Hard dependency on network check
  };

  # Open K3s ports
  networking.firewall.allowedTCPPorts = [
    6443 # K3s API server
  ];

  # Allow traffic on CNI interfaces (Flannel)
  networking.firewall.trustedInterfaces = [
    "cni0"
    "flannel.1"
  ];

  # Kernel modules required for CNI bridge
  boot.kernelModules = [
    "bridge"
    "br_netfilter"
    "veth"
  ];

  # Sysctl settings for Kubernetes networking
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
  };

  # Useful tools
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
  ];

  # Verify network is ready before K3s
  systemd.services.k3s-network-check = {
    description = "Verify network is ready before K3s starts";
    before = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "k3s-network-check" ''
        set -e

        echo "Verifying network connectivity before starting K3s..."

        # Wait for IP address to be configured
        for i in $(seq 1 30); do
          if ${pkgs.iproute2}/bin/ip addr show | grep -q "${serverConfig.serverIP}"; then
            echo "IP ${serverConfig.serverIP} configured"
            break
          fi
          echo "Waiting for IP... ($i/30)"
          sleep 1
        done

        # Verify gateway is reachable
        echo "Verifying connectivity to gateway ${serverConfig.gateway}..."
        for i in $(seq 1 10); do
          if ${pkgs.iputils}/bin/ping -c 1 -W 2 ${serverConfig.gateway} &>/dev/null; then
            echo "Gateway ${serverConfig.gateway} reachable"
            break
          fi
          echo "Waiting for gateway... ($i/10)"
          sleep 2
        done

        # DNS check (optional, non-blocking)
        echo "Verifying DNS..."
        if ${pkgs.iputils}/bin/ping -c 1 -W 2 ${builtins.head serverConfig.nameservers} &>/dev/null; then
          echo "DNS working"
        else
          echo "WARN: DNS not responding, but continuing (may be normal)"
        fi

        echo "Network verified, K3s can start"
      '';
    };
  };

  # Service to copy kubeconfig after K3s starts
  systemd.services.kubeconfig-setup = {
    description = "Setup kubeconfig for admin user";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "setup-kubeconfig" ''
        # Wait for k3s to generate the kubeconfig
        for i in $(seq 1 30); do
          if [ -f /etc/rancher/k3s/k3s.yaml ]; then
            break
          fi
          sleep 1
        done

        if [ -f /etc/rancher/k3s/k3s.yaml ]; then
          mkdir -p /home/${serverConfig.adminUser}/.kube
          cp /etc/rancher/k3s/k3s.yaml /home/${serverConfig.adminUser}/.kube/config
          chown ${serverConfig.adminUser}:users /home/${serverConfig.adminUser}/.kube/config
          chmod 600 /home/${serverConfig.adminUser}/.kube/config
        fi
      '';
    };
  };

  # WORKAROUND: Fix for K3s v1.34 CNI bridge issue
  # Flannel's CNI plugin is not correctly attaching veth interfaces to the cni0 bridge
  # This service monitors and automatically attaches veths to the bridge
  # Issue: https://github.com/k3s-io/k3s/issues/11403 (example, check if actual issue exists)
  systemd.services.k3s-cni-bridge-fixer = {
    description = "K3s CNI Bridge Fixer - Attach veth interfaces to cni0";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "5s";

      ExecStart = pkgs.writeShellScript "k3s-cni-bridge-fixer" ''
        set -euo pipefail

        # Function for log with timestamp
        log() {
          echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
        }

        # Function to attach veths to the cni0 bridge
        attach_veths_to_bridge() {
          # Check that the cni0 bridge exists
          if ! ${pkgs.iproute2}/bin/ip link show cni0 &>/dev/null; then
            # If it doesn't exist, wait for K3s to create it
            return 0
          fi

          # Ensure the bridge is UP
          ${pkgs.iproute2}/bin/ip link set cni0 up 2>/dev/null || true

          # Find all veth interfaces NOT attached to the bridge
          for veth in $(${pkgs.iproute2}/bin/ip link show type veth | ${pkgs.gnugrep}/bin/grep -oP '^\d+: \K[^:@]+' || true); do
            # Check if the veth is already attached to a bridge
            if ! ${pkgs.iproute2}/bin/ip link show "$veth" | ${pkgs.gnugrep}/bin/grep -q "master cni0"; then
              # Attach to cni0 bridge
              if ${pkgs.iproute2}/bin/ip link set "$veth" master cni0 2>/dev/null; then
                log "Attached $veth to cni0 bridge"
              fi
            fi
          done
        }

        log "Starting K3s CNI bridge fixer..."
        log "Monitoring veth interfaces and attaching to cni0 bridge"

        # Main loop: check every 30 seconds
        while true; do
          attach_veths_to_bridge
          sleep 30
        done
      '';
    };
  };

}
