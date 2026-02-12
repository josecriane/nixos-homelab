#!/usr/bin/env bash
# NAS-Server integration verification
# Run on the server: sudo ./scripts/verify-nas-integration.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Load NAS IP from config.nix
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.nix"
if [ -f "$CONFIG_FILE" ]; then
    NAS_IP=$(grep -A10 'nas1 = {' "$CONFIG_FILE" 2>/dev/null | grep -E '^\s*ip\s*=' | sed 's/.*"\(.*\)".*/\1/' || echo "")
    DOMAIN=$(grep 'domain =' "$CONFIG_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    SUBDOMAIN=$(grep 'subdomain =' "$CONFIG_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')
else
    echo -e "${RED}Error: config.nix not found${NC}"
    exit 1
fi

if [ -z "$NAS_IP" ]; then
    echo -e "${RED}Error: NAS IP not configured in config.nix${NC}"
    exit 1
fi

BASE_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
COCKPIT_PORT="9090"
FILEBROWSER_PORT="8080"

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  NAS-Server Integration Verification${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

check_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
}

check_warn() {
    echo -e "${YELLOW}!${NC} $1"
}

# 1. config.nix
echo -e "${BLUE}[1/10] Checking config.nix...${NC}"
if grep -q "nas = {" "$CONFIG_FILE" && grep -q "enabled = true" "$CONFIG_FILE"; then
    check_ok "NAS configuration enabled in config.nix"
else
    check_fail "NAS not enabled in config.nix"
    exit 1
fi
echo ""

# 2. Systemd services
echo -e "${BLUE}[2/10] Checking systemd services...${NC}"
if systemctl is-active --quiet nas-integration-setup.service; then
    check_ok "nas-integration-setup.service active"
else
    check_warn "nas-integration-setup.service not active"
fi

if systemctl is-active --quiet authentik-nas-apps-setup.service; then
    check_ok "authentik-nas-apps-setup.service active"
else
    check_warn "authentik-nas-apps-setup.service not active"
fi
echo ""

# 3. Markers
echo -e "${BLUE}[3/10] Checking markers...${NC}"
if [ -f /var/lib/nas-integration-setup-done ]; then
    check_ok "NAS integration marker exists"
else
    check_fail "NAS integration marker missing"
fi

if [ -f /var/lib/authentik-nas-apps-done ]; then
    check_ok "Authentik NAS apps marker exists"
else
    check_fail "Authentik NAS apps marker missing"
fi
echo ""

# 4. Namespace
echo -e "${BLUE}[4/10] Checking namespace 'nas'...${NC}"
if kubectl get namespace nas &>/dev/null; then
    check_ok "Namespace 'nas' exists"
else
    check_fail "Namespace 'nas' does not exist"
    exit 1
fi
echo ""

# 5. Services
echo -e "${BLUE}[5/10] Checking services...${NC}"
if kubectl get svc -n nas nas-cockpit &>/dev/null; then
    check_ok "Service 'nas-cockpit' exists"
else
    check_fail "Service 'nas-cockpit' does not exist"
fi

if kubectl get svc -n nas nas-filebrowser &>/dev/null; then
    check_ok "Service 'nas-filebrowser' exists"
else
    check_fail "Service 'nas-filebrowser' does not exist"
fi
echo ""

# 6. Endpoints
echo -e "${BLUE}[6/10] Checking endpoints...${NC}"
COCKPIT_ENDPOINT=$(kubectl get endpoints -n nas nas-cockpit -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
if [ "$COCKPIT_ENDPOINT" = "$NAS_IP" ]; then
    check_ok "Endpoint nas-cockpit points to $NAS_IP"
else
    check_fail "Endpoint nas-cockpit does not point to $NAS_IP (actual: $COCKPIT_ENDPOINT)"
fi

FILEBROWSER_ENDPOINT=$(kubectl get endpoints -n nas nas-filebrowser -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
if [ "$FILEBROWSER_ENDPOINT" = "$NAS_IP" ]; then
    check_ok "Endpoint nas-filebrowser points to $NAS_IP"
else
    check_fail "Endpoint nas-filebrowser does not point to $NAS_IP (actual: $FILEBROWSER_ENDPOINT)"
fi
echo ""

# 7. IngressRoutes
echo -e "${BLUE}[7/10] Checking IngressRoutes...${NC}"
if kubectl get ingressroute -n nas nas-cockpit &>/dev/null; then
    check_ok "IngressRoute 'nas-cockpit' exists"
    COCKPIT_HOST=$(kubectl get ingressroute -n nas nas-cockpit -o jsonpath='{.spec.routes[0].match}' | grep -oP 'Host\(\K[^)]+' | tr -d '`')
    echo -e "   Host: ${YELLOW}$COCKPIT_HOST${NC}"
else
    check_fail "IngressRoute 'nas-cockpit' does not exist"
fi

if kubectl get ingressroute -n nas nas-filebrowser &>/dev/null; then
    check_ok "IngressRoute 'nas-filebrowser' exists"
    FILEBROWSER_HOST=$(kubectl get ingressroute -n nas nas-filebrowser -o jsonpath='{.spec.routes[0].match}' | grep -oP 'Host\(\K[^)]+' | tr -d '`')
    echo -e "   Host: ${YELLOW}$FILEBROWSER_HOST${NC}"
else
    check_fail "IngressRoute 'nas-filebrowser' does not exist"
fi
echo ""

# 8. ForwardAuth middleware
echo -e "${BLUE}[8/10] Checking ForwardAuth middleware...${NC}"
if kubectl get middleware -n traefik-system authentik-forward-auth &>/dev/null; then
    check_ok "Middleware 'authentik-forward-auth' exists"
    FORWARD_AUTH_URL=$(kubectl get middleware -n traefik-system authentik-forward-auth -o jsonpath='{.spec.forwardAuth.address}')
    echo -e "   Address: ${YELLOW}$FORWARD_AUTH_URL${NC}"
else
    check_fail "Middleware 'authentik-forward-auth' does not exist"
fi
echo ""

# 9. NAS connectivity
echo -e "${BLUE}[9/10] Checking NAS connectivity...${NC}"
if ping -c 1 -W 2 "$NAS_IP" &>/dev/null; then
    check_ok "NAS ($NAS_IP) is reachable"
else
    check_fail "NAS ($NAS_IP) is not reachable"
fi

if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$NAS_IP/$COCKPIT_PORT" 2>/dev/null; then
    check_ok "Cockpit responding on $NAS_IP:$COCKPIT_PORT"
else
    check_warn "Cockpit not responding on $NAS_IP:$COCKPIT_PORT"
fi

if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$NAS_IP/$FILEBROWSER_PORT" 2>/dev/null; then
    check_ok "FileBrowser responding on $NAS_IP:$FILEBROWSER_PORT"
else
    check_warn "FileBrowser not responding on $NAS_IP:$FILEBROWSER_PORT"
fi
echo ""

# 10. Wildcard certificate
echo -e "${BLUE}[10/10] Checking wildcard certificate...${NC}"
CERT_NAME="wildcard-${SUBDOMAIN}-$(echo "$DOMAIN" | tr '.' '-')-tls"
if kubectl get secret -n nas "$CERT_NAME" &>/dev/null; then
    check_ok "Wildcard certificate copied to namespace 'nas'"
else
    check_warn "Wildcard certificate not in namespace 'nas'"
fi
echo ""

# Summary
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo -e "Access URLs:"
echo -e "  - Cockpit:     ${GREEN}https://nas.${BASE_DOMAIN}${NC}"
echo -e "  - FileBrowser: ${GREEN}https://files.${BASE_DOMAIN}${NC}"
echo ""
echo -e "Useful commands:"
echo -e "  ${YELLOW}kubectl get all -n nas${NC}               # View NAS resources"
echo -e "  ${YELLOW}kubectl logs -n nas <pod>${NC}            # View logs"
echo -e "  ${YELLOW}journalctl -u nas-integration-setup${NC}  # View setup logs"
echo ""

# Optional HTTP test
read -p "Run HTTP test to NAS? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Testing HTTP...${NC}"
    if command -v curl &>/dev/null; then
        echo -e "${YELLOW}Cockpit:${NC}"
        curl -I "http://$NAS_IP:$COCKPIT_PORT" 2>/dev/null | head -5 || echo "Error"
        echo ""
        echo -e "${YELLOW}FileBrowser:${NC}"
        curl -I "http://$NAS_IP:$FILEBROWSER_PORT" 2>/dev/null | head -5 || echo "Error"
    else
        echo "curl is not installed"
    fi
fi

echo ""
echo -e "${GREEN}Verification complete${NC}"
