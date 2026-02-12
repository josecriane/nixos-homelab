#!/usr/bin/env bash
set -e

# Auto-enter nix-shell with dependencies if not already there
if [ -z "$IN_NIX_SHELL" ] && command -v nix-shell &> /dev/null; then
    exec nix-shell -p jq curl --run "IN_NIX_SHELL=1 $0 $*"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.nix"
SERVER_IP=$(grep 'serverIP' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
DOMAIN=$(grep '^ *domain =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
SUBDOMAIN=$(grep '^ *subdomain =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
BASE_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
ADMIN_USER=$(grep 'adminUser =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

# URLs
VAULTWARDEN_URL="https://vault.${BASE_DOMAIN}"
AUTHENTIK_URL="https://auth.${BASE_DOMAIN}"
GRAFANA_URL="https://grafana.${BASE_DOMAIN}"

# State file
STATE_FILE="/tmp/wizard-state-$$"
touch "$STATE_FILE"

# Functions
print_header() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}       ${BOLD}NixOS Homelab - Configuration Wizard${NC}               ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step() {
    local step=$1
    local total=$2
    local title=$3
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Step $step of $total: $title${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

wait_for_enter() {
    echo ""
    echo -e "${YELLOW}Press ENTER when you have completed this step...${NC}"
    read -r
}

wait_for_yes() {
    local prompt=$1
    echo ""
    while true; do
        echo -e "${YELLOW}$prompt (y/n): ${NC}"
        read -r answer
        case $answer in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer 'y' or 'n'";;
        esac
    done
}

check_url() {
    local url=$1
    local name=$2
    echo -n "  Verifying $name... "
    if curl -sk --connect-timeout 5 "$url" > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}NOT AVAILABLE${NC}"
        return 1
    fi
}

open_url() {
    local url=$1
    echo -e "  ${CYAN}URL: ${BOLD}$url${NC}"

    # Try to open in browser
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" 2>/dev/null &
    elif command -v open &> /dev/null; then
        open "$url" 2>/dev/null &
    fi
}

ssh_cmd() {
    ssh -o ConnectTimeout=5 "${ADMIN_USER}@${SERVER_IP}" "$@" 2>/dev/null
}

# ============================================================================
# STEP 1: Verify Services
# ============================================================================
step_verify_services() {
    print_header
    print_step 1 5 "Verify Services"

    echo -e "${BOLD}Verifying that the main services are available...${NC}"
    echo ""

    local all_ok=true

    check_url "$VAULTWARDEN_URL" "Vaultwarden" || all_ok=false
    check_url "$AUTHENTIK_URL" "Authentik" || all_ok=false
    check_url "$GRAFANA_URL" "Grafana" || all_ok=false
    check_url "https://home.${BASE_DOMAIN}" "Homarr" || all_ok=false

    echo ""

    if [ "$all_ok" = false ]; then
        echo -e "${RED}Some services are not available.${NC}"
        echo -e "Wait a few minutes and run the wizard again."
        echo -e "You can check the status with: ${CYAN}./scripts/status.sh${NC}"
        exit 1
    fi

    echo -e "${GREEN}All main services are available.${NC}"
    wait_for_enter
}

# ============================================================================
# STEP 2: Configure Authentik Admin
# ============================================================================
step_authentik_setup() {
    print_header
    print_step 2 5 "Configure Authentik (SSO)"

    # Get Authentik password
    AUTHENTIK_PASS=$(ssh_cmd "sudo cat /run/agenix/authentik-admin-password 2>/dev/null" || echo "")

    if [ -z "$AUTHENTIK_PASS" ]; then
        echo -e "${YELLOW}Could not get the Authentik password.${NC}"
        echo -e "Check the file: /run/agenix/authentik-admin-password"
        wait_for_enter
        return
    fi

    echo -e "${BOLD}Authentik${NC} is your Single Sign-On (SSO) server."
    echo -e "It allows unified login for: Jellyfin, Grafana, Nextcloud, Immich, etc."
    echo ""
    echo -e "${BOLD}Admin credentials:${NC}"
    echo -e "  User:     ${CYAN}akadmin${NC}"
    echo -e "  Password: ${CYAN}$AUTHENTIK_PASS${NC}"
    echo ""

    # Get API token via authentication
    AUTHENTIK_TOKEN=$(curl -sk -X POST "$AUTHENTIK_URL/api/v3/core/tokens/" \
        -H "Content-Type: application/json" \
        -u "akadmin:$AUTHENTIK_PASS" \
        -d '{"identifier":"wizard-setup","intent":"api"}' 2>/dev/null | jq -r '.key // empty' 2>/dev/null || echo "")

    # Fallback: try to get bootstrap token from K8s secret
    if [ -z "$AUTHENTIK_TOKEN" ]; then
        AUTHENTIK_TOKEN=$(ssh_cmd "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl get secret authentik-setup-credentials -n authentik -o jsonpath='{.data.BOOTSTRAP_TOKEN}' 2>/dev/null" | base64 -d 2>/dev/null || echo "")
    fi

    if [ -z "$AUTHENTIK_TOKEN" ]; then
        echo -e "${YELLOW}Could not get API token. Manual configuration needed.${NC}"
        echo ""
        echo -e "  1. Open ${CYAN}$AUTHENTIK_URL${NC}"
        echo -e "  2. Login with akadmin / the password above"
        echo -e "  3. Go to Directory > Users > Create"
        open_url "$AUTHENTIK_URL"
        wait_for_enter
        return
    fi

    AUTH_HEADER="Authorization: Bearer $AUTHENTIK_TOKEN"

    echo -e "${BOLD}Let's create your personal user in Authentik.${NC}"
    echo ""
    echo -e -n "${CYAN}Username: ${NC}"
    read -r AK_USERNAME
    echo -e -n "${CYAN}Email: ${NC}"
    read -r AK_EMAIL
    echo -e -n "${CYAN}Full name: ${NC}"
    read -r AK_NAME
    echo -e -n "${CYAN}Password: ${NC}"
    read -rs AK_PASSWORD
    echo ""
    echo ""

    if [ -z "$AK_USERNAME" ] || [ -z "$AK_EMAIL" ] || [ -z "$AK_PASSWORD" ]; then
        echo -e "${RED}All fields are required.${NC}"
        wait_for_enter
        return
    fi

    # Create user
    echo -e "Creating user..."
    USER_RESULT=$(curl -sk -X POST "$AUTHENTIK_URL/api/v3/core/users/" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"$AK_USERNAME\",
            \"name\": \"$AK_NAME\",
            \"email\": \"$AK_EMAIL\",
            \"is_active\": true
        }" 2>&1)

    USER_PK=$(echo "$USER_RESULT" | jq -r '.pk // empty' 2>/dev/null || echo "")

    if [ -n "$USER_PK" ]; then
        echo -e "${GREEN}User created.${NC}"

        # Set password
        curl -sk -X POST "$AUTHENTIK_URL/api/v3/core/users/$USER_PK/set_password/" \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -d "{\"password\": \"$AK_PASSWORD\"}" >/dev/null 2>&1

        echo -e "${GREEN}Password set.${NC}"

        # Add to admins group
        ADMINS_GROUP_PK=$(curl -sk "$AUTHENTIK_URL/api/v3/core/groups/?search=admins" \
            -H "$AUTH_HEADER" 2>/dev/null | jq -r '.results[0].pk // empty' 2>/dev/null || echo "")

        if [ -z "$ADMINS_GROUP_PK" ]; then
            # Create admins group
            ADMINS_GROUP_PK=$(curl -sk -X POST "$AUTHENTIK_URL/api/v3/core/groups/" \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -d '{"name":"admins","is_superuser":true}' 2>/dev/null | jq -r '.pk // empty' 2>/dev/null || echo "")
        fi

        if [ -n "$ADMINS_GROUP_PK" ]; then
            curl -sk -X POST "$AUTHENTIK_URL/api/v3/core/groups/$ADMINS_GROUP_PK/add_user/" \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -d "{\"pk\": $USER_PK}" >/dev/null 2>&1
            echo -e "${GREEN}User added to admins group.${NC}"
        fi
    else
        ERROR_MSG=$(echo "$USER_RESULT" | jq -r '.username[0] // .detail // "unknown error"' 2>/dev/null || echo "error")
        echo -e "${YELLOW}Could not create user: $ERROR_MSG${NC}"
        echo -e "Create it manually at: ${CYAN}$AUTHENTIK_URL${NC} > Directory > Users"
    fi

    # Cleanup token
    curl -sk -X DELETE "$AUTHENTIK_URL/api/v3/core/tokens/wizard-setup/" \
        -H "$AUTH_HEADER" >/dev/null 2>&1 || true

    wait_for_enter
}

# ============================================================================
# STEP 3: Test SSO Login
# ============================================================================
step_test_sso() {
    print_header
    print_step 3 5 "Test SSO"

    echo -e "${BOLD}Let's test that SSO is working correctly.${NC}"
    echo ""
    echo -e "${BOLD}Test in Grafana:${NC}"
    echo -e "  1. Open ${CYAN}https://grafana.${BASE_DOMAIN}${NC}"
    echo -e "  2. Click '${CYAN}Sign in with Authentik${NC}'"
    echo -e "  3. Login with your Authentik user"
    echo -e "  4. You should enter as Admin (if you are in the 'admins' group)"
    echo ""

    open_url "https://grafana.${BASE_DOMAIN}"

    if wait_for_yes "Were you able to login to Grafana with SSO?"; then
        echo -e "${GREEN}Grafana SSO working.${NC}"
    else
        echo -e "${YELLOW}Check the Authentik configuration.${NC}"
    fi

    echo ""
    echo -e "${BOLD}Other services with SSO:${NC}"
    echo -e "  - Jellyfin: ${CYAN}https://jellyfin.${BASE_DOMAIN}${NC}"
    echo -e "  - Nextcloud: ${CYAN}https://cloud.${BASE_DOMAIN}${NC} (Log in with Authentik)"
    echo -e "  - Immich: ${CYAN}https://photos.${BASE_DOMAIN}${NC}"
    echo -e "  - Jellyseerr: ${CYAN}https://requests.${BASE_DOMAIN}${NC}"
    echo ""

    wait_for_enter
}

# ============================================================================
# STEP 4: Configure Kavita OIDC
# ============================================================================
show_kavita_oidc_manual() {
    echo ""
    echo -e "${BOLD}Configure manually in Kavita UI:${NC}"
    echo -e "  1. Open ${CYAN}https://kavita.${BASE_DOMAIN}${NC}"
    echo -e "  2. Login as admin"
    echo -e "  3. Admin > Settings > Authentication"
    echo -e "  4. Enable OIDC"
    echo -e "  5. Client ID: ${CYAN}kavita${NC}"
    echo -e "  6. Client Secret: ${CYAN}$KAVITA_CLIENT_SECRET${NC}"
    echo -e "  7. Authority: ${CYAN}https://auth.${BASE_DOMAIN}/application/o/kavita/${NC}"
    echo ""
    open_url "https://kavita.${BASE_DOMAIN}"
}

step_kavita_oidc() {
    print_header
    print_step 4 5 "Configure OIDC in Kavita"

    echo -e "${BOLD}Kavita${NC} supports login with Authentik (OIDC)."
    echo ""

    # Check if Kavita is running
    if ! ssh_cmd "sudo k3s kubectl get deploy kavita -n media" &>/dev/null; then
        echo -e "${YELLOW}Kavita is not deployed. Skip this step.${NC}"
        wait_for_enter
        return
    fi

    # Get credentials from K8s secrets
    KAVITA_CLIENT_SECRET=$(ssh_cmd "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl get secret authentik-sso-credentials -n media -o jsonpath='{.data.KAVITA_CLIENT_SECRET}' 2>/dev/null" | base64 -d 2>/dev/null || echo "")
    KAVITA_PASS=$(ssh_cmd "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl get secret kavita-credentials -n media -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null" | base64 -d 2>/dev/null || echo "")

    if [ -z "$KAVITA_CLIENT_SECRET" ] || [ -z "$KAVITA_PASS" ]; then
        echo -e "${YELLOW}Missing credentials (SSO or Kavita admin).${NC}"
        echo -e "Run an update to regenerate the services."
        wait_for_enter
        return
    fi

    echo -e "Configuring OIDC via API..."

    # Login to Kavita (curl inside the pod)
    TOKEN=$(ssh_cmd "sudo k3s kubectl exec -n media deploy/kavita -- \
        curl -s -X POST http://localhost:5000/api/Account/login \
        -H 'Content-Type: application/json' \
        -d '{\"username\":\"admin\",\"password\":\"${KAVITA_PASS}\"}'" | jq -r '.token // empty' 2>/dev/null)

    if [ -z "$TOKEN" ]; then
        echo -e "${YELLOW}Could not login to Kavita API.${NC}"
        show_kavita_oidc_manual
        wait_for_enter
        return
    fi

    # Get current settings
    SETTINGS=$(ssh_cmd "sudo k3s kubectl exec -n media deploy/kavita -- \
        curl -s http://localhost:5000/api/Settings \
        -H 'Authorization: Bearer ${TOKEN}'" 2>/dev/null)

    # Already configured?
    if [ "$(echo "$SETTINGS" | jq -r '.oidcConfig.enabled')" = "true" ]; then
        echo -e "${GREEN}OIDC is already configured in Kavita.${NC}"
        wait_for_enter
        return
    fi

    # Update settings with OIDC
    AUTHORITY="https://auth.${BASE_DOMAIN}/application/o/kavita/"
    UPDATED=$(echo "$SETTINGS" | jq \
        --arg csec "$KAVITA_CLIENT_SECRET" \
        --arg auth "$AUTHORITY" \
        '.oidcConfig.enabled = true | .oidcConfig.clientId = "kavita" | .oidcConfig.secret = $csec | .oidcConfig.authority = $auth')

    # Write modified settings into pod via stdin, then POST
    echo "$UPDATED" | jq -c . | \
        ssh_cmd "sudo k3s kubectl exec -i -n media deploy/kavita -- tee /tmp/oidc.json" > /dev/null 2>&1

    RESULT=$(ssh_cmd "sudo k3s kubectl exec -n media deploy/kavita -- \
        curl -s -X POST http://localhost:5000/api/Settings \
        -H 'Authorization: Bearer ${TOKEN}' \
        -H 'Content-Type: application/json' \
        -d @/tmp/oidc.json" 2>/dev/null)

    ssh_cmd "sudo k3s kubectl exec -n media deploy/kavita -- rm -f /tmp/oidc.json" 2>/dev/null

    if echo "$RESULT" | jq -e '.' &>/dev/null 2>&1; then
        echo -e "${GREEN}OIDC configured successfully in Kavita.${NC}"
        echo ""
        echo -e "Authentik login available at:"
        echo -e "  ${CYAN}https://kavita.${BASE_DOMAIN}${NC}"
    else
        echo -e "${YELLOW}Error updating settings.${NC}"
        show_kavita_oidc_manual
    fi

    wait_for_enter
}

# ============================================================================
# STEP 5: Summary
# ============================================================================
step_summary() {
    print_header
    print_step 5 5 "Final Summary"

    echo -e "${GREEN}${BOLD}Configuration completed!${NC}"
    echo ""
    echo -e "${BOLD}Configured services:${NC}"
    echo ""
    echo -e "┌─────────────────────────────────────────────────────────────────┐"
    echo -e "│ ${BOLD}SSO (Authentik)${NC} - Unified login                               │"
    echo -e "├─────────────────────────────────────────────────────────────────┤"
    echo -e "│  Grafana        https://grafana.${BASE_DOMAIN}              │"
    echo -e "│  Jellyfin       https://jellyfin.${BASE_DOMAIN}             │"
    echo -e "│  Nextcloud      https://cloud.${BASE_DOMAIN}                │"
    echo -e "│  Immich         https://photos.${BASE_DOMAIN}               │"
    echo -e "│  Jellyseerr     https://requests.${BASE_DOMAIN}             │"
    echo -e "│  Vaultwarden    https://vault.${BASE_DOMAIN}                │"
    echo -e "│  Kavita         https://kavita.${BASE_DOMAIN}               │"
    echo -e "├─────────────────────────────────────────────────────────────────┤"
    echo -e "│ ${BOLD}Local Auth${NC} - Credentials in Vaultwarden                        │"
    echo -e "├─────────────────────────────────────────────────────────────────┤"
    echo -e "│  Sonarr         https://sonarr.${BASE_DOMAIN}               │"
    echo -e "│  Sonarr ES      https://sonarr-es.${BASE_DOMAIN}            │"
    echo -e "│  Radarr         https://radarr.${BASE_DOMAIN}               │"
    echo -e "│  Radarr ES      https://radarr-es.${BASE_DOMAIN}            │"
    echo -e "│  Prowlarr       https://prowlarr.${BASE_DOMAIN}             │"
    echo -e "│  Lidarr         https://lidarr.${BASE_DOMAIN}               │"
    echo -e "│  Bazarr         https://bazarr.${BASE_DOMAIN}               │"
    echo -e "│  qBittorrent    https://qbit.${BASE_DOMAIN}                 │"
    echo -e "│  Bookshelf      https://books.${BASE_DOMAIN}                │"
    echo -e "│  Kavita         https://kavita.${BASE_DOMAIN}               │"
    echo -e "│  Syncthing      https://sync.${BASE_DOMAIN}                 │"
    echo -e "├─────────────────────────────────────────────────────────────────┤"
    echo -e "│ ${BOLD}Monitoring${NC}                                                     │"
    echo -e "├─────────────────────────────────────────────────────────────────┤"
    echo -e "│  Homarr         https://home.${BASE_DOMAIN}                 │"
    echo -e "│  Prometheus     https://prometheus.${BASE_DOMAIN}           │"
    echo -e "│  Alertmanager   https://alertmanager.${BASE_DOMAIN}         │"
    echo -e "│  Uptime Kuma    https://status.${BASE_DOMAIN}               │"
    echo -e "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${GREEN}All configurations have been automated.${NC}"
    echo ""
    echo -e "${BOLD}Suggested next steps:${NC}"
    echo -e "  1. Upload your photos to Immich"
    echo -e "  2. Configure Syncthing for file synchronization"
    echo -e "  3. Add your media libraries to Jellyfin"
    echo -e ""
    echo -e "${BOLD}Automatic configuration:${NC}"
    echo -e "  Connections between services (Prowlarr, Sonarr, Radarr,"
    echo -e "  qBittorrent, Jellyfin) are configured automatically."
    echo ""
    echo -e "${CYAN}Main dashboard: ${BOLD}https://home.${BASE_DOMAIN}${NC}"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    # Check dependencies
    if ! command -v curl &> /dev/null; then
        echo "Error: curl is not installed"
        exit 1
    fi

    if ! command -v ssh &> /dev/null; then
        echo "Error: ssh is not installed"
        exit 1
    fi

    # Check server connectivity
    if ! ssh -o ConnectTimeout=5 "${ADMIN_USER}@${SERVER_IP}" "echo ok" &>/dev/null; then
        echo -e "${RED}Error: Cannot connect to server ${SERVER_IP}${NC}"
        echo "Verify the server is powered on and accessible."
        exit 1
    fi

    # Run steps
    step_verify_services
    step_authentik_setup
    step_test_sso
    step_kavita_oidc
    step_summary

    # Cleanup
    rm -f "$STATE_FILE"
}

# Run main
main "$@"
