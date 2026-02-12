#!/usr/bin/env bash
# Post-install verification
# Run: ./scripts/verify.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.nix"
if [ -f "$CONFIG_FILE" ]; then
    SERVER_IP=$(grep 'serverIP' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
    SERVER_USER=$(grep 'adminUser =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
    DOMAIN=$(grep 'domain =' "$CONFIG_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    SUBDOMAIN=$(grep 'subdomain =' "$CONFIG_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')
else
    echo -e "${RED}Error: config.nix not found${NC}"
    echo "Copy config.example.nix to config.nix and fill in your settings."
    exit 1
fi

BASE_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

echo -e "${YELLOW}Verifying homelab installation...${NC}"
echo ""

remote() {
    ssh -o ConnectTimeout=5 "$SERVER_USER@$SERVER_IP" "$@" 2>/dev/null
}

check() {
    local name="$1"
    local result="$2"
    if [ -n "$result" ] && [ "$result" != "0" ] && [ "$result" != "NOT FOUND" ] && [ "$result" != "NO" ]; then
        echo -e "  ${GREEN}✓${NC} $name"
        return 0
    else
        echo -e "  ${RED}✗${NC} $name"
        return 1
    fi
}

# Connectivity
echo -e "${YELLOW}1. Connectivity${NC}"
if remote "echo ok" | grep -q "ok"; then
    echo -e "  ${GREEN}✓${NC} SSH to server ($SERVER_IP)"
else
    echo -e "  ${RED}✗${NC} Cannot connect to server"
    exit 1
fi

# K3s
echo ""
echo -e "${YELLOW}2. Kubernetes (K3s)${NC}"

K3S_STATUS=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes -o jsonpath='{.items[0].status.conditions[-1].type}'" 2>/dev/null)
check "K3s node Ready" "$K3S_STATUS"

PROBLEM_PODS=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l")
if [ "$PROBLEM_PODS" = "0" ]; then
    echo -e "  ${GREEN}✓${NC} All pods Running"
else
    echo -e "  ${YELLOW}!${NC} $PROBLEM_PODS pods with issues"
fi

# DNS
echo ""
echo -e "${YELLOW}3. DNS (CoreDNS)${NC}"

DNS_FORWARD=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get cm -n kube-system coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -o 'forward \. [0-9.]*'")
if [ -n "$DNS_FORWARD" ]; then
    FORWARD_IP=$(echo "$DNS_FORWARD" | grep -o '[0-9.]*$')
    echo -e "  ${GREEN}✓${NC} CoreDNS forwarding to $FORWARD_IP"
else
    echo -e "  ${RED}✗${NC} CoreDNS forwarding not configured"
fi

# Main services
echo ""
echo -e "${YELLOW}4. Main services${NC}"

SERVICES=(
    "authentik:authentik:Authentik"
    "traefik-system:traefik:Traefik"
    "monitoring:grafana:Grafana"
    "monitoring:prometheus:Prometheus"
    "nextcloud:nextcloud:Nextcloud"
    "media:jellyfin:Jellyfin"
    "media:jellyseerr:Jellyseerr"
    "media:sonarr:Sonarr"
    "media:radarr:Radarr"
    "media:prowlarr:Prowlarr"
    "immich:server:Immich"
    "vaultwarden:vaultwarden:Vaultwarden"
)

for svc in "${SERVICES[@]}"; do
    NS="${svc%%:*}"
    REST="${svc#*:}"
    LABEL="${REST%%:*}"
    NAME="${REST##*:}"

    STATUS=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get pods -n $NS -l app.kubernetes.io/name=$LABEL -o jsonpath='{.items[0].status.phase}'" 2>/dev/null)
    check "$NAME" "$STATUS"
done

# SSO
echo ""
echo -e "${YELLOW}5. SSO (Authentik)${NC}"

MW=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get middleware -n traefik-system authentik-forward-auth -o name" 2>/dev/null)
check "Middleware ForwardAuth" "$MW"

SSO_SECRET=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get secret -n traefik-system authentik-sso-credentials -o name" 2>/dev/null)
check "SSO credentials secret" "$SSO_SECRET"

GRAFANA_OIDC=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get secret -n monitoring grafana-oidc-env -o name" 2>/dev/null)
check "Grafana OIDC secret" "$GRAFANA_OIDC"

# Authentik groups
echo ""
echo -e "${YELLOW}6. Authentik groups${NC}"

AK_GROUPS=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml exec -n authentik \$(sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get pods -n authentik -l app.kubernetes.io/name=authentik -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}') -- /lifecycle/ak shell -c \"from authentik.core.models import Group; print(','.join([g.name for g in Group.objects.filter(name__in=['admins','media-admins','media-users','family','monitoring'])]))\"" 2>/dev/null | tail -1)

for group in admins media-admins media-users family monitoring; do
    if echo "$AK_GROUPS" | grep -q "$group"; then
        echo -e "  ${GREEN}✓${NC} Group: $group"
    else
        echo -e "  ${RED}✗${NC} Group: $group"
    fi
done

# OIDC applications
echo ""
echo -e "${YELLOW}7. OIDC applications${NC}"

APPS=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml exec -n authentik \$(sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get pods -n authentik -l app.kubernetes.io/name=authentik -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}') -- /lifecycle/ak shell -c \"from authentik.core.models import Application; print(','.join([a.slug for a in Application.objects.all()]))\"" 2>/dev/null | tail -1)

for app in grafana nextcloud jellyfin jellyseerr immich vaultwarden; do
    if echo "$APPS" | grep -q "$app"; then
        echo -e "  ${GREEN}✓${NC} App: $app"
    else
        echo -e "  ${RED}✗${NC} App: $app"
    fi
done

# PVCs
echo ""
echo -e "${YELLOW}8. Persistence (PVCs)${NC}"

PVC_COUNT=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get pvc -A --no-headers 2>/dev/null | wc -l")
BOUND_COUNT=$(remote "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get pvc -A --no-headers 2>/dev/null | grep Bound | wc -l")

if [ "$PVC_COUNT" = "$BOUND_COUNT" ]; then
    echo -e "  ${GREEN}✓${NC} $PVC_COUNT PVCs (all Bound)"
else
    echo -e "  ${YELLOW}!${NC} $BOUND_COUNT/$PVC_COUNT PVCs Bound"
fi

# Accessible URLs
echo ""
echo -e "${YELLOW}9. Accessible URLs (from your machine)${NC}"

URLS=(
    "https://home.${BASE_DOMAIN}:Homarr"
    "https://auth.${BASE_DOMAIN}:Authentik"
    "https://grafana.${BASE_DOMAIN}:Grafana"
    "https://cloud.${BASE_DOMAIN}:Nextcloud"
    "https://jellyfin.${BASE_DOMAIN}:Jellyfin"
    "https://photos.${BASE_DOMAIN}:Immich"
)

for url_name in "${URLS[@]}"; do
    URL="${url_name%%:*}"
    NAME="${url_name##*:}"

    if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "$URL" 2>/dev/null | grep -qE "^(200|302|301|401|403)$"; then
        echo -e "  ${GREEN}✓${NC} $NAME"
    else
        echo -e "  ${RED}✗${NC} $NAME ($URL)"
    fi
done

# Summary
echo ""
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}Verification complete${NC}"
echo ""
echo "Next steps for new installation:"
echo "  1. Go to https://auth.${BASE_DOMAIN}"
echo "  2. Login: akadmin / (see /run/agenix/authentik-admin-password)"
echo "  3. Create a user and assign to the 'admins' group"
echo "  4. Test SSO at https://grafana.${BASE_DOMAIN}"
