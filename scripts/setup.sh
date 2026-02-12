#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.nix"
SECRETS_DIR="$PROJECT_DIR/secrets"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         NixOS Server - Initial Setup                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify dependencies
MISSING_DEPS=()
command -v age &>/dev/null || MISSING_DEPS+=("age")
command -v ssh-keygen &>/dev/null || MISSING_DEPS+=("openssh")

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo -e "${RED}Error: Missing dependencies: ${MISSING_DEPS[*]}${NC}"
    echo ""
    echo "Install them with:"
    echo "  nix-shell -p ${MISSING_DEPS[*]} --run \"$0\""
    echo ""
    echo "Or permanently:"
    echo "  nix profile install nixpkgs#age"
    exit 1
fi

# Function to prompt with a default value
ask() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${GREEN}$prompt${NC} [$default]: ")" value
        value="${value:-$default}"
    else
        read -rp "$(echo -e "${GREEN}$prompt${NC}: ")" value
    fi

    eval "$var_name='$value'"
}

# Function to prompt for secret (no echo)
ask_secret() {
    local prompt="$1"
    local var_name="$2"

    read -srp "$(echo -e "${GREEN}$prompt${NC}: ")" value
    echo ""
    eval "$var_name='$value'"
}

# Confirmation function
confirm() {
    local prompt="$1"
    read -rp "$(echo -e "${YELLOW}$prompt${NC} [y/N]: ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

# ===============================================================
# READ EXISTING CONFIGURATION
# ===============================================================
# Function to extract value from config.nix
get_config() {
    local key="$1"
    local default="$2"
    if [[ -f "$CONFIG_FILE" ]]; then
        # Extract value from nix file (handles strings and booleans)
        local value
        value=$(grep -E "^\s*$key\s*=" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//;s/[";]//g;s/\s*$//')
        if [[ -n "$value" ]]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

# Load existing config if present
if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "${GREEN}Existing configuration detected in config.nix${NC}"
    echo -e "${YELLOW}Current values will be shown as defaults.${NC}"
    echo ""

    # Load current values
    CURRENT_SERVER_NAME=$(get_config "serverName" "homelab")
    CURRENT_SERVER_IP=$(get_config "serverIP" "192.168.1.100")
    CURRENT_GATEWAY=$(get_config "gateway" "192.168.1.1")
    CURRENT_DNS=$(grep 'nameservers' "$CONFIG_FILE" 2>/dev/null | sed 's/.*\[\s*"//;s/".*//' || echo "192.168.1.1")
    CURRENT_METALLB_START=$(get_config "metallbPoolStart" "192.168.1.200")
    CURRENT_METALLB_END=$(get_config "metallbPoolEnd" "192.168.1.254")
    CURRENT_DOMAIN=$(get_config "domain" "yourdomain.com")
    CURRENT_SUBDOMAIN=$(get_config "subdomain" "in")
    CURRENT_ADMIN_USER=$(get_config "adminUser" "admin")
    CURRENT_ACME_EMAIL=$(get_config "acmeEmail" "admin@$CURRENT_DOMAIN")
    CURRENT_TIMEZONE=$(get_config "timezone" "UTC")
    CURRENT_USE_WIFI=$(get_config "useWifi" "false")
    CURRENT_WIFI_SSID=$(get_config "wifiSSID" "")

    # NAS config
    CURRENT_NAS_IP=$(grep -A10 'nas1 = {' "$CONFIG_FILE" 2>/dev/null | grep -E '^\s*ip\s*=' | sed 's/.*=\s*"//;s/".*//' || echo "192.168.1.10")
    CURRENT_NAS_HOSTNAME=$(grep -A10 'nas1 = {' "$CONFIG_FILE" 2>/dev/null | grep -E '^\s*hostname\s*=' | sed 's/.*=\s*"//;s/".*//' || echo "nas1")
    CURRENT_USE_NFS=$(grep -A3 'storage = {' "$CONFIG_FILE" 2>/dev/null | grep 'useNFS' | sed 's/.*=\s*//;s/[;]//g' || echo "false")
else
    echo -e "${YELLOW}This script will guide you through the initial setup.${NC}"
    echo -e "${YELLOW}You will need to have ready:${NC}"
    echo "  - Cloudflare API Token (if you have one)"
    echo "  - Tailscale Auth Key (if you have one)"
    echo "  - Your SSH public key"
    echo ""

    # Set defaults for new install
    CURRENT_SERVER_NAME="homelab"
    CURRENT_SERVER_IP="192.168.1.100"
    CURRENT_GATEWAY="192.168.1.1"
    CURRENT_DNS="192.168.1.1"
    CURRENT_METALLB_START="192.168.1.200"
    CURRENT_METALLB_END="192.168.1.220"
    CURRENT_DOMAIN="yourdomain.com"
    CURRENT_SUBDOMAIN="in"
    CURRENT_ADMIN_USER="admin"
    CURRENT_ACME_EMAIL=""
    CURRENT_TIMEZONE="UTC"
    CURRENT_USE_WIFI="false"
    CURRENT_WIFI_SSID=""
    CURRENT_NAS_IP="192.168.1.50"
    CURRENT_NAS_HOSTNAME="nas1"
    CURRENT_USE_NFS="false"
fi

# ===============================================================
# SERVER CONFIGURATION
# ===============================================================
echo -e "\n${BLUE}=== Server Configuration ===${NC}\n"

ask "Server name (hostname)" "$CURRENT_SERVER_NAME" SERVER_NAME

# ===============================================================
# NETWORK CONFIGURATION
# ===============================================================
echo -e "\n${BLUE}=== Network Configuration ===${NC}\n"

ask "Server IP" "$CURRENT_SERVER_IP" SERVER_IP
ask "Gateway (router)" "$CURRENT_GATEWAY" GATEWAY
ask "DNS (Pi-hole IP)" "$CURRENT_DNS" DNS_SERVER
ask "MetalLB range start" "$CURRENT_METALLB_START" METALLB_START
ask "MetalLB range end" "$CURRENT_METALLB_END" METALLB_END

# WiFi
echo ""
if [[ "$CURRENT_USE_WIFI" == "true" ]]; then
    if confirm "Will the server connect via WiFi? (current: yes)"; then
        USE_WIFI="true"
        ask "WiFi network name (SSID)" "$CURRENT_WIFI_SSID" WIFI_SSID
        ask_secret "WiFi network password" WIFI_PASSWORD
    else
        USE_WIFI="false"
        WIFI_SSID=""
        WIFI_PASSWORD=""
    fi
else
    if confirm "Will the server connect via WiFi?"; then
        USE_WIFI="true"
        ask "WiFi network name (SSID)" "" WIFI_SSID
        ask_secret "WiFi network password" WIFI_PASSWORD
    else
        USE_WIFI="false"
        WIFI_SSID=""
        WIFI_PASSWORD=""
    fi
fi

# ===============================================================
# DOMAIN CONFIGURATION
# ===============================================================
echo -e "\n${BLUE}=== Domain Configuration ===${NC}\n"

ask "Your domain" "$CURRENT_DOMAIN" DOMAIN
ask "Subdomain for internal services" "$CURRENT_SUBDOMAIN" SUBDOMAIN

echo -e "\n${YELLOW}Your services will be accessible at: *.${SUBDOMAIN}.${DOMAIN}${NC}"
echo -e "Example: vault.${SUBDOMAIN}.${DOMAIN}, grafana.${SUBDOMAIN}.${DOMAIN}\n"

# ===============================================================
# USER CONFIGURATION
# ===============================================================
echo -e "\n${BLUE}=== Admin User ===${NC}\n"

ask "Admin username" "$CURRENT_ADMIN_USER" ADMIN_USER
DEFAULT_EMAIL="${CURRENT_ACME_EMAIL:-admin@$DOMAIN}"
ask "Email (for Let's Encrypt)" "$DEFAULT_EMAIL" ACME_EMAIL
ask "Timezone" "$CURRENT_TIMEZONE" TIMEZONE

# SSH Key - auto detect
echo -e "\n${GREEN}Detecting SSH key...${NC}"
SSH_KEY=""
for keyfile in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$keyfile" ]]; then
        SSH_KEY=$(cat "$keyfile")
        echo -e "${GREEN}✓ Found: $keyfile${NC}"
        echo -e "  ${YELLOW}${SSH_KEY:0:60}...${NC}"
        break
    fi
done

if [[ -z "$SSH_KEY" ]]; then
    echo -e "${RED}No SSH key found in ~/.ssh/${NC}"
    echo -e "${YELLOW}Generate one with: ssh-keygen -t ed25519${NC}"
    ask "Paste your SSH public key" "" SSH_KEY
fi

# ===============================================================
# SUDO HARDENING (optional)
# ===============================================================
echo -e "\n${BLUE}=== Sudo Security (optional) ===${NC}\n"

ADMIN_PASSWORD_HASH=""
echo -e "${YELLOW}By default, sudo requires no password (convenient but less secure).${NC}"
echo -e "${YELLOW}You can set a password to require sudo authentication.${NC}"
echo -e "${YELLOW}Common commands (nixos-rebuild, systemctl, journalctl, kubectl) will${NC}"
echo -e "${YELLOW}remain passwordless for convenience.${NC}"
echo ""

if confirm "Set a sudo password for $ADMIN_USER?"; then
    while true; do
        ask_secret "Sudo password" ADMIN_SUDO_PASS
        if [[ ${#ADMIN_SUDO_PASS} -lt 8 ]]; then
            echo -e "${RED}Password must be at least 8 characters${NC}"
            continue
        fi
        ask_secret "Confirm password" ADMIN_SUDO_PASS_CONFIRM
        if [[ "$ADMIN_SUDO_PASS" != "$ADMIN_SUDO_PASS_CONFIRM" ]]; then
            echo -e "${RED}Passwords don't match, try again${NC}"
            continue
        fi
        break
    done

    if command -v mkpasswd &>/dev/null; then
        ADMIN_PASSWORD_HASH=$(mkpasswd -m sha-512 "$ADMIN_SUDO_PASS")
    else
        ADMIN_PASSWORD_HASH=$(echo -n "$ADMIN_SUDO_PASS" | openssl passwd -6 -stdin 2>/dev/null || echo "")
    fi

    if [[ -n "$ADMIN_PASSWORD_HASH" ]]; then
        echo -e "${GREEN}Password hash generated${NC}"
    else
        echo -e "${RED}Could not generate password hash. Install mkpasswd or openssl.${NC}"
        echo -e "${YELLOW}You can set this up later manually.${NC}"
    fi
fi

echo ""

# ===============================================================
# SERVICE SELECTION
# ===============================================================
echo -e "\n${BLUE}=== Service Selection ===${NC}\n"

# Services by category
declare -A SERVICES

# Load current services from config if exists
get_service() {
    local svc="$1"
    local default="$2"
    if [[ -f "$CONFIG_FILE" ]]; then
        local val
        val=$(grep -A20 'services = {' "$CONFIG_FILE" 2>/dev/null | grep "$svc" | sed 's/.*=\s*//;s/[;]//g' | tr -d ' ')
        [[ -n "$val" ]] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

CURRENT_SVC_VAULTWARDEN=$(get_service "vaultwarden" "true")
CURRENT_SVC_AUTHENTIK=$(get_service "authentik" "true")
CURRENT_SVC_NEXTCLOUD=$(get_service "nextcloud" "true")
CURRENT_SVC_MONITORING=$(get_service "monitoring" "true")
CURRENT_SVC_MEDIA=$(get_service "media" "true")
CURRENT_SVC_IMMICH=$(get_service "immich" "true")
CURRENT_SVC_SYNCTHING=$(get_service "syncthing" "true")
CURRENT_SVC_KIWIX=$(get_service "kiwix" "false")
CURRENT_SVC_VAULT=$(get_service "vault" "false")

if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}Current services detected. Press Enter to keep.${NC}\n"
else
    echo -e "${YELLOW}Select which services you want to install.${NC}\n"
fi

# Core (always installed)
echo -e "${GREEN}Core (always included):${NC}"
echo "  ✓ K3s, MetalLB, Traefik, cert-manager"
echo "  ✓ Homarr (dashboard)"
echo ""

# Helper to ask about services with current state
ask_service() {
    local desc="$1"
    local current="$2"
    local varname="$3"

    if [[ "$current" == "true" ]]; then
        if confirm "  $desc (current: ✓)?"; then
            SERVICES[$varname]=true
        else
            SERVICES[$varname]=false
        fi
    else
        if confirm "  $desc?"; then
            SERVICES[$varname]=true
        else
            SERVICES[$varname]=false
        fi
    fi
}

echo -e "${GREEN}Optional services:${NC}\n"

ask_service "Vaultwarden (password manager)" "$CURRENT_SVC_VAULTWARDEN" "vaultwarden"
ask_service "Authentik (SSO/Identity)" "$CURRENT_SVC_AUTHENTIK" "authentik"
ask_service "Nextcloud (cloud storage)" "$CURRENT_SVC_NEXTCLOUD" "nextcloud"
ask_service "Monitoring (Grafana + Prometheus)" "$CURRENT_SVC_MONITORING" "monitoring"

ask_service "Media stack (Jellyfin, *arr, qBittorrent)" "$CURRENT_SVC_MEDIA" "media"
ask_service "Immich (photo backup)" "$CURRENT_SVC_IMMICH" "immich"
ask_service "Syncthing (file sync)" "$CURRENT_SVC_SYNCTHING" "syncthing"
ask_service "Kiwix (offline Wikipedia + iFixit)" "$CURRENT_SVC_KIWIX" "kiwix"
ask_service "HashiCorp Vault (infrastructure secrets)" "$CURRENT_SVC_VAULT" "vault"

echo ""

# ===============================================================
# NAS STORAGE CONFIGURATION
# ===============================================================
echo -e "\n${BLUE}=== NAS Storage Configuration ===${NC}\n"

# Load current NAS exports if exist
CURRENT_NAS_DATA_EXPORT=$(grep -A15 'nfsExports = {' "$CONFIG_FILE" 2>/dev/null | grep -E '^\s*data\s*=' | sed 's/.*=\s*"//;s/".*//' || echo "/mnt/storage")
CURRENT_NAS_MEDIA_EXPORT=$(grep -A15 'nfsExports = {' "$CONFIG_FILE" 2>/dev/null | grep -E '^\s*media\s*=' | sed 's/.*=\s*"//;s/".*//' || echo "/mnt/storage/media")
CURRENT_NAS_DOWNLOADS_EXPORT=$(grep -A15 'nfsExports = {' "$CONFIG_FILE" 2>/dev/null | grep -E '^\s*downloads\s*=' | sed 's/.*=\s*"//;s/".*//' || echo "/mnt/storage/downloads")
CURRENT_NAS_ROLE=$(grep -A10 'nas1 = {' "$CONFIG_FILE" 2>/dev/null | grep -E '^\s*role\s*=' | sed 's/.*=\s*"//;s/".*//' || echo "media")

USE_NFS="false"
NAS_IP=""
NAS_HOSTNAME=""
NAS_ROLE="$CURRENT_NAS_ROLE"
NAS_DATA_EXPORT="$CURRENT_NAS_DATA_EXPORT"
NAS_MEDIA_EXPORT="$CURRENT_NAS_MEDIA_EXPORT"
NAS_DOWNLOADS_EXPORT="$CURRENT_NAS_DOWNLOADS_EXPORT"

echo -e "${YELLOW}NFS storage lets you use an external NAS for media.${NC}"
echo -e "${YELLOW}If you don't configure NAS, local storage will be used.${NC}"
echo ""

# Helper function to configure NAS
configure_nas() {
    ask "NAS IP" "$CURRENT_NAS_IP" NAS_IP

    # Verify connectivity
    echo -e "${YELLOW}Verifying connectivity...${NC}"
    if ping -c 1 -W 3 "$NAS_IP" &>/dev/null; then
        echo -e "${GREEN}✓ NAS reachable${NC}"

        # Try to list exports
        if command -v showmount &>/dev/null; then
            echo -e "\n${GREEN}Available NFS exports:${NC}"
            showmount -e "$NAS_IP" 2>/dev/null || echo "  (could not list exports)"
            echo ""
        fi
    else
        echo -e "${YELLOW}⚠ Could not contact the NAS. Continuing...${NC}"
    fi

    ask "NAS hostname" "$CURRENT_NAS_HOSTNAME" NAS_HOSTNAME

    echo -e "\n${GREEN}NAS role:${NC}"
    echo "  1) media   - Media storage (movies, series, music)"
    echo "  2) backups - Backup storage"
    echo "  3) all     - All storage"
    read -rp "$(echo -e "${GREEN}Select role${NC} [1]: ")" role_choice
    case "$role_choice" in
        2) NAS_ROLE="backups" ;;
        3) NAS_ROLE="all" ;;
        *) NAS_ROLE="media" ;;
    esac

    echo -e "\n${GREEN}NFS export paths:${NC}"
    ask "Main export (/data)" "$NAS_DATA_EXPORT" NAS_DATA_EXPORT
    ask "Media export" "$NAS_MEDIA_EXPORT" NAS_MEDIA_EXPORT
    ask "Downloads export" "$NAS_DOWNLOADS_EXPORT" NAS_DOWNLOADS_EXPORT

    echo ""
    echo -e "${GREEN}NAS configured:${NC}"
    echo "  IP: $NAS_IP"
    echo "  Hostname: $NAS_HOSTNAME"
    echo "  Role: $NAS_ROLE"
    echo "  Exports: $NAS_DATA_EXPORT, $NAS_MEDIA_EXPORT, $NAS_DOWNLOADS_EXPORT"
}

# Show current status and ask for configuration
if [[ "$CURRENT_USE_NFS" == "true" ]]; then
    echo -e "${GREEN}Current NAS: $CURRENT_NAS_IP ($CURRENT_NAS_HOSTNAME)${NC}"
    if confirm "Keep current NAS configuration?"; then
        USE_NFS="true"
        NAS_IP="$CURRENT_NAS_IP"
        NAS_HOSTNAME="$CURRENT_NAS_HOSTNAME"
    elif confirm "Reconfigure NAS storage?"; then
        USE_NFS="true"
        configure_nas
    else
        USE_NFS="false"
        echo -e "${YELLOW}NAS disabled. Local storage will be used.${NC}"
    fi
elif confirm "Configure NAS storage (NFS)?"; then
    USE_NFS="true"
    configure_nas
else
    echo -e "${YELLOW}Using local storage (hostPath)${NC}"
fi

echo ""

# ===============================================================
# SERVICE CREDENTIALS
# ===============================================================
echo -e "\n${BLUE}=== Service Credentials ===${NC}\n"

AUTHENTIK_PASSWORD=""
AUTHENTIK_EMAIL=""

if [[ "${SERVICES[authentik]}" == "true" ]]; then
    echo -e "${YELLOW}Configure the Authentik admin (user: akadmin):${NC}\n"
    ask "Admin email" "$ACME_EMAIL" AUTHENTIK_EMAIL
    ask_secret "Admin password (minimum 8 characters)" AUTHENTIK_PASSWORD

    if [[ ${#AUTHENTIK_PASSWORD} -lt 8 ]]; then
        echo -e "${RED}⚠ Password too short, using default value${NC}"
        AUTHENTIK_PASSWORD="changeme123"
    fi
fi

VAULTWARDEN_PASSWORD=""
OPENSUBTITLES_USER=""
OPENSUBTITLES_PASSWORD=""

if [[ "${SERVICES[vaultwarden]}" == "true" ]]; then
    echo -e "${YELLOW}Configure the Vaultwarden admin user:${NC}\n"
    ask_secret "Vaultwarden admin password (minimum 8 characters)" VAULTWARDEN_PASSWORD

    if [[ ${#VAULTWARDEN_PASSWORD} -lt 8 ]]; then
        echo -e "${RED}⚠ Password too short, using default value${NC}"
        VAULTWARDEN_PASSWORD="changeme123"
    fi
fi

if [[ "${SERVICES[media]}" == "true" ]]; then
    echo -e "${YELLOW}OpenSubtitles.com credentials (for automatic subtitles):${NC}\n"
    ask "OpenSubtitles.com username (leave empty to skip)" "" OPENSUBTITLES_USER
    if [[ -n "$OPENSUBTITLES_USER" ]]; then
        ask_secret "OpenSubtitles.com password" OPENSUBTITLES_PASSWORD
    fi
fi

# ===============================================================
# SECRETS (OPTIONAL FOR NOW)
# ===============================================================
echo -e "\n${BLUE}=== Secrets (optional, you can add them later) ===${NC}\n"

CLOUDFLARE_TOKEN=""
TAILSCALE_KEY=""

if confirm "Do you have the Cloudflare API Token?"; then
    ask_secret "Cloudflare API Token" CLOUDFLARE_TOKEN
fi

if confirm "Do you have the Tailscale Auth Key?"; then
    ask_secret "Tailscale Auth Key" TAILSCALE_KEY
fi

# ===============================================================
# SAVE CONFIGURATION
# ===============================================================
echo -e "\n${BLUE}=== Saving configuration ===${NC}\n"

# Save SSH key to keys/admin.pub
mkdir -p "$PROJECT_DIR/keys"
echo "$SSH_KEY" > "$PROJECT_DIR/keys/admin.pub"
echo -e "${GREEN}✓ SSH key saved to keys/admin.pub${NC}"

# Create config.nix
cat > "$CONFIG_FILE" << EOF
# Server configuration - Generated by setup.sh
# Regenerate with: ./scripts/setup.sh
{
  # Server
  serverName = "$SERVER_NAME";

  # Network
  serverIP = "$SERVER_IP";
  gateway = "$GATEWAY";
  nameservers = [ "$DNS_SERVER" ];

  # WiFi
  useWifi = $USE_WIFI;
  wifiSSID = "$WIFI_SSID";

  # Domain
  domain = "$DOMAIN";
  subdomain = "$SUBDOMAIN";

  # Admin user
  adminUser = "$ADMIN_USER";
  adminSSHKeys = [
    (builtins.readFile ./keys/admin.pub)
  ];

  # Container user/group IDs (match adminUser)
  puid = 1000;
  pgid = 1000;

  # Email for Let's Encrypt
  acmeEmail = "$ACME_EMAIL";

  # Kubernetes
  metallbPoolStart = "$METALLB_START";
  metallbPoolEnd = "$METALLB_END";
  traefikIP = "$METALLB_START";

  # Timezone
  timezone = "$TIMEZONE";

  # Enabled services
  services = {
    vaultwarden = ${SERVICES[vaultwarden]};
    authentik = ${SERVICES[authentik]};
    nextcloud = ${SERVICES[nextcloud]};
    monitoring = ${SERVICES[monitoring]};
    media = ${SERVICES[media]};
    immich = ${SERVICES[immich]};
    syncthing = ${SERVICES[syncthing]};
    kiwix = ${SERVICES[kiwix]};
    vault = ${SERVICES[vault]};
  };

  # Authentik credentials (if enabled)
  authentik = {
    adminEmail = "$AUTHENTIK_EMAIL";
  };

  # NAS Integration
  nas = {
    nas1 = {
      enabled = $USE_NFS;
      ip = "$NAS_IP";
      hostname = "$NAS_HOSTNAME";
      role = "$NAS_ROLE";
      nfsExports = {
        data = "$NAS_DATA_EXPORT";
        media = "$NAS_MEDIA_EXPORT";
        downloads = "$NAS_DOWNLOADS_EXPORT";
      };
      cockpitPort = 9090;
      fileBrowserPort = 8080;
      description = "Main NAS";
    };
  };

  # Storage configuration
  storage = {
    useNFS = $USE_NFS;
  };

  # OpenSubtitles.com (for Bazarr subtitle downloads)
  opensubtitles = {
    username = "$OPENSUBTITLES_USER";
  };
}
EOF

echo -e "${GREEN}✓ Configuration saved to config.nix${NC}"

# ===============================================================
# GENERATE SERVER SSH KEYS (for agenix)
# ===============================================================
mkdir -p "$SECRETS_DIR"

SERVER_KEY_DIR="$SECRETS_DIR/server-keys"
mkdir -p "$SERVER_KEY_DIR"

if [[ ! -f "$SERVER_KEY_DIR/ssh_host_ed25519_key" ]]; then
    echo -e "\n${BLUE}=== Generating server SSH keys ===${NC}\n"
    ssh-keygen -t ed25519 -f "$SERVER_KEY_DIR/ssh_host_ed25519_key" -N "" -C "root@$SERVER_NAME"
    echo -e "${GREEN}✓ Server SSH keys generated${NC}"
else
    echo -e "${GREEN}✓ Server SSH keys already exist${NC}"
fi

SERVER_PUBLIC_KEY=$(cat "$SERVER_KEY_DIR/ssh_host_ed25519_key.pub")

# Extract user public key for agenix
ADMIN_PUBLIC_KEY=$(echo "$SSH_KEY" | awk '{print $1 " " $2}')

# Create secrets.nix for agenix
cat > "$SECRETS_DIR/secrets.nix" << EOF
let
  # Server public key (generated by setup.sh)
  server = "$SERVER_PUBLIC_KEY";

  # Your public key for encrypt/decrypt
  admin = "$ADMIN_PUBLIC_KEY";

  allKeys = [ server admin ];
in
{
  "cloudflare-api-token.age".publicKeys = allKeys;
  "tailscale-auth-key.age".publicKeys = allKeys;
  "wifi-password.age".publicKeys = allKeys;
  "authentik-admin-password.age".publicKeys = allKeys;
  "vaultwarden-admin-password.age".publicKeys = allKeys;
  "opensubtitles-password.age".publicKeys = allKeys;
  "admin-password-hash.age".publicKeys = allKeys;
}
EOF

# Encrypt secrets with age
RECIPIENTS="$SERVER_KEY_DIR/ssh_host_ed25519_key.pub"

if [[ -n "$CLOUDFLARE_TOKEN" ]]; then
    echo -n "$CLOUDFLARE_TOKEN" | age -R "$RECIPIENTS" -o "$SECRETS_DIR/cloudflare-api-token.age"
    echo -e "${GREEN}✓ Cloudflare token encrypted${NC}"
fi

if [[ -n "$TAILSCALE_KEY" ]]; then
    echo -n "$TAILSCALE_KEY" | age -R "$RECIPIENTS" -o "$SECRETS_DIR/tailscale-auth-key.age"
    echo -e "${GREEN}✓ Tailscale key encrypted${NC}"
fi

if [[ -n "$WIFI_PASSWORD" ]]; then
    echo -n "$WIFI_PASSWORD" | age -R "$RECIPIENTS" -o "$SECRETS_DIR/wifi-password.age"
    echo -e "${GREEN}✓ WiFi password encrypted${NC}"
fi

if [[ -n "$AUTHENTIK_PASSWORD" ]]; then
    echo -n "$AUTHENTIK_PASSWORD" | age -R "$RECIPIENTS" -o "$SECRETS_DIR/authentik-admin-password.age"
    echo -e "${GREEN}✓ Authentik password encrypted${NC}"
fi

if [[ -n "$VAULTWARDEN_PASSWORD" ]]; then
    echo -n "$VAULTWARDEN_PASSWORD" | age -R "$RECIPIENTS" -o "$SECRETS_DIR/vaultwarden-admin-password.age"
    echo -e "${GREEN}✓ Vaultwarden password encrypted${NC}"
fi

if [[ -n "$OPENSUBTITLES_PASSWORD" ]]; then
    echo -n "$OPENSUBTITLES_PASSWORD" | age -R "$RECIPIENTS" -o "$SECRETS_DIR/opensubtitles-password.age"
    echo -e "${GREEN}✓ OpenSubtitles.com password encrypted${NC}"
fi

if [[ -n "$ADMIN_PASSWORD_HASH" ]]; then
    echo -n "$ADMIN_PASSWORD_HASH" | age -R "$RECIPIENTS" -o "$SECRETS_DIR/admin-password-hash.age"
    echo -e "${GREEN}✓ Admin password hash encrypted (sudo will require password)${NC}"
fi

# ===============================================================
# VERIFY FLAKE
# ===============================================================
echo -e "\n${BLUE}=== Verifying configuration ===${NC}\n"

cd "$PROJECT_DIR"
if nix flake check 2>/dev/null; then
    echo -e "${GREEN}✓ Flake valid${NC}"
else
    echo -e "${YELLOW}⚠ Flake has errors (normal if secrets are missing)${NC}"
fi

# ===============================================================
# SUMMARY
# ===============================================================
echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Setup Complete                             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Server:${NC}     $SERVER_IP"
echo -e "  ${GREEN}Domain:${NC}      *.$SUBDOMAIN.$DOMAIN"
echo -e "  ${GREEN}User:${NC}       $ADMIN_USER"
echo -e "  ${GREEN}MetalLB:${NC}      $METALLB_START - $METALLB_END"
echo ""
echo -e "  ${GREEN}Selected services:${NC}"
for svc in "${!SERVICES[@]}"; do
    if [[ "${SERVICES[$svc]}" == "true" ]]; then
        echo -e "    ✓ $svc"
    fi
done
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo "  1. Prepare the physical server:"
echo "     - Boot with NixOS USB"
echo "     - Run: sudo systemctl start sshd && sudo passwd nixos"
echo ""
echo "  2. Install NixOS:"
echo "     ./scripts/install.sh"
echo ""

if [[ -z "$CLOUDFLARE_TOKEN" ]] || [[ -z "$TAILSCALE_KEY" ]]; then
    echo -e "${YELLOW}  Note: Missing secrets. You can add them by running setup.sh again.${NC}"
    echo ""
fi

# ===============================================================
# CONFIGURE PI-HOLE
# ===============================================================
echo -e "${BLUE}=== Pi-hole Configuration ===${NC}"
echo ""
echo "Add this line on your Raspberry Pi (/etc/dnsmasq.d/02-internal.conf):"
echo ""
echo -e "  ${GREEN}address=/$SUBDOMAIN.$DOMAIN/$METALLB_START${NC}"
echo ""
echo "Then restart Pi-hole: sudo pihole restartdns"
echo ""
