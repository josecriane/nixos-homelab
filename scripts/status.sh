#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.nix"

# Read configuration
SERVER_IP=$(grep 'serverIP' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
ADMIN_USER=$(grep 'adminUser =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              NixOS Server - Status                           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify connectivity
echo -e "${YELLOW}Connectivity:${NC}"
if ping -c 1 -W 2 "$SERVER_IP" &>/dev/null; then
    echo -e "  Ping:     ${GREEN}✓${NC}"
else
    echo -e "  Ping:     ${RED}✗${NC}"
fi

if ssh -o ConnectTimeout=5 "$ADMIN_USER@$SERVER_IP" "echo ok" &>/dev/null; then
    echo -e "  SSH:      ${GREEN}✓${NC}"
else
    echo -e "  SSH:      ${RED}✗${NC}"
    exit 1
fi

# Run commands on the server
echo ""
echo -e "${YELLOW}System:${NC}"
ssh "$ADMIN_USER@$SERVER_IP" "
    UPTIME=\$(awk '{d=int(\$1/86400);h=int(\$1%86400/3600);m=int(\$1%3600/60);printf \"%dd %dh %dm\",d,h,m}' /proc/uptime)

    # CPU
    CPU_CORES=\$(nproc)
    CPU_LOAD=\$(awk '{print \$1}' /proc/loadavg)

    # Memory
    MEM_INFO=\$(free -h | awk '/^Mem:/ {print \$3 \"/\" \$2}')
    MEM_PERCENT=\$(free | awk '/^Mem:/ {printf \"%.0f\", \$3/\$2 * 100}')

    echo \"  Hostname: \$(hostname)\"
    echo \"  Uptime:   \$UPTIME\"
    echo \"  CPU:      \$CPU_CORES cores, load: \$CPU_LOAD\"
    echo \"  Memory:   \$MEM_INFO (\$MEM_PERCENT%)\"
"

# Disk status
echo ""
echo -e "${YELLOW}Storage:${NC}"
ssh "$ADMIN_USER@$SERVER_IP" "
    echo '  Physical disks:'
    df -h -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1 {printf \"    %-20s %s/%s (%s used)\\n\", \$6, \$3, \$2, \$5}'

    echo ''
    echo '  Kubernetes PVCs:'
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    if command -v kubectl &>/dev/null && kubectl get pvc -A &>/dev/null 2>&1; then
        kubectl get pvc -A --no-headers 2>/dev/null | awk '{printf \"    %-20s %-25s %s\\n\", \$1, \$2, \$4}' | head -15
        PVC_COUNT=\$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)
        if [ \"\$PVC_COUNT\" -gt 15 ]; then
            echo \"    ... and \$((PVC_COUNT - 15)) more\"
        fi
    else
        echo '    (K8s not available)'
    fi
"

# Service status
echo ""
echo -e "${YELLOW}NixOS Services:${NC}"
ssh "$ADMIN_USER@$SERVER_IP" '
    GREEN="\033[0;32m"
    RED="\033[0;31m"
    NC="\033[0m"
    for svc in sshd tailscaled k3s; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            echo -e "  $svc: ${GREEN}✓${NC}"
        else
            echo -e "  $svc: ${RED}✗${NC}"
        fi
    done
'

# Tailscale
echo ""
echo -e "${YELLOW}Tailscale:${NC}"
ssh "$ADMIN_USER@$SERVER_IP" "
    if command -v tailscale &>/dev/null; then
        TS_STATUS=\$(tailscale status --json 2>/dev/null | grep -o '\"BackendState\":\"[^\"]*\"' | cut -d'\"' -f4 || echo 'unknown')
        TS_IP=\$(tailscale ip -4 2>/dev/null || echo 'N/A')
        echo \"  Status:   \$TS_STATUS\"
        echo \"  IP:       \$TS_IP\"
    else
        echo '  Not installed'
    fi
"

# K8s status
echo ""
echo -e "${YELLOW}Kubernetes:${NC}"
if ssh "$ADMIN_USER@$SERVER_IP" "command -v kubectl &>/dev/null"; then
    ssh "$ADMIN_USER@$SERVER_IP" '
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        GREEN="\033[0;32m"
        YELLOW="\033[1;33m"
        RED="\033[0;31m"
        NC="\033[0m"

        if kubectl get nodes &>/dev/null 2>&1; then
            echo -e "  Cluster: ${GREEN}✓${NC}"
            echo ""
            echo "  Nodes:"
            kubectl get nodes --no-headers | while read line; do
                echo "    $line"
            done
            echo ""
            echo "  Pods per namespace:"
            kubectl get pods -A --no-headers 2>/dev/null | awk -v g="$GREEN" -v y="$YELLOW" -v nc="$NC" "{
                ns[\$1]++
                if (\$4 == \"Running\" || \$4 == \"Completed\") running[\$1]++
            } END {
                for (n in ns) {
                    r = running[n] ? running[n] : 0
                    if (r == ns[n]) {
                        printf \"    %-20s %d/%d %s✓%s\n\", n, r, ns[n], g, nc
                    } else {
                        printf \"    %-20s %d/%d %s!%s\n\", n, r, ns[n], y, nc
                    }
                }
            }" | sort

            # Problem pods
            PROBLEM_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | awk "\$4 != \"Running\" && \$4 != \"Completed\" {print \$1\"/\"\$2}")
            if [ -n "$PROBLEM_PODS" ]; then
                echo ""
                echo "  Problem pods:"
                echo "$PROBLEM_PODS" | while read pod; do
                    echo -e "    ${RED}✗${NC} $pod"
                done
            fi
        else
            echo -e "  Cluster: ${RED}✗${NC} (not available)"
        fi
    '
else
    echo "  kubectl not installed"
fi

# Service URLs
echo ""
echo -e "${YELLOW}Service URLs:${NC}"
SUBDOMAIN=$(grep 'subdomain' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
DOMAIN=$(grep 'domain' "$CONFIG_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')
echo -e "  Dashboard:    ${CYAN}https://home.${SUBDOMAIN}.${DOMAIN}${NC}"
echo -e "  Grafana:      ${CYAN}https://grafana.${SUBDOMAIN}.${DOMAIN}${NC}"
echo -e "  Vaultwarden:  ${CYAN}https://vault.${SUBDOMAIN}.${DOMAIN}${NC}"

echo ""
