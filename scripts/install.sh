#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.nix"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         NixOS Server - Installation                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify that config.nix exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: config.nix not found${NC}"
    echo "Run first: ./scripts/setup.sh"
    exit 1
fi

# Read server IP from config.nix
SERVER_IP=$(grep 'serverIP' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

echo -e "${GREEN}Server:${NC} $SERVER_IP"
echo ""

# Verify connectivity
echo -e "${YELLOW}Verifying connectivity with the server...${NC}"
if ! ping -c 1 -W 2 "$SERVER_IP" &>/dev/null; then
    echo -e "${RED}Cannot reach $SERVER_IP${NC}"
    echo "Verify the server is powered on and connected to the network."
    exit 1
fi
echo -e "${GREEN}✓ Server reachable${NC}"

# Clean known_hosts to avoid conflicts with reinstallations
ssh-keygen -R "$SERVER_IP" &>/dev/null || true

# Detect SSH user (existing NixOS or installation ISO)
echo -e "${YELLOW}Detecting SSH user...${NC}"
ADMIN_USER=$(grep 'adminUser =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$ADMIN_USER@$SERVER_IP" "echo ok" &>/dev/null; then
    SSH_USER="$ADMIN_USER"
    echo -e "${GREEN}✓ Connecting as $SSH_USER (existing NixOS)${NC}"
elif command -v sshpass &>/dev/null && sshpass -p nixos ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "nixos@$SERVER_IP" "echo ok" &>/dev/null; then
    SSH_USER="nixos"
    echo -e "${GREEN}✓ Connecting as nixos (installation ISO)${NC}"
elif ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "nixos@$SERVER_IP" "echo ok" &>/dev/null; then
    SSH_USER="nixos"
    echo -e "${GREEN}✓ Connecting as nixos (existing SSH key)${NC}"
else
    echo -e "${YELLOW}Could not detect SSH user automatically${NC}"
    echo ""
    echo "Which user to connect to $SERVER_IP?"
    echo "  1) nixos (installation ISO)"
    echo "  2) $ADMIN_USER (existing NixOS)"
    read -rp "Select [1/2]: " choice
    case "$choice" in
        1) SSH_USER="nixos" ;;
        2) SSH_USER="$ADMIN_USER" ;;
        *) echo "Invalid option"; exit 1 ;;
    esac
    echo -e "${GREEN}✓ Using user: $SSH_USER${NC}"
fi

# Copy SSH key (required for nixos-anywhere)
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$SERVER_IP" "echo ok" &>/dev/null; then
    echo -e "${YELLOW}Copying SSH key to the server...${NC}"
    if [[ "$SSH_USER" == "nixos" ]]; then
        # nixos user with password "nixos" configured manually on the server
        if command -v sshpass &>/dev/null; then
            echo -e "${YELLOW}Using sshpass to copy SSH key (password: nixos)...${NC}"
            sshpass -p nixos ssh-copy-id -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "$SSH_USER@$SERVER_IP"
        else
            echo -e "${YELLOW}sshpass not available. Enter the password for user nixos:${NC}"
            ssh-copy-id -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "$SSH_USER@$SERVER_IP" </dev/tty
        fi
    else
        echo -e "${YELLOW}Enter the password for user $SSH_USER:${NC}"
        ssh-copy-id -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "$SSH_USER@$SERVER_IP" </dev/tty
    fi
    if ! ssh -o BatchMode=yes "$SSH_USER@$SERVER_IP" "echo ok" &>/dev/null; then
        echo -e "${RED}Could not copy SSH key. nixos-anywhere requires it.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✓ SSH key configured${NC}"

# Detect disk
echo -e "${YELLOW}Detecting available disks...${NC}"
echo ""

# Show all disks with useful information
ssh -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "lsblk -dpo NAME,SIZE,MODEL,LABEL | grep -E '/dev/(sd|nvme|vd)'"
echo ""

# Detect the installation USB (has label nixos-minimal or similar)
USB_DISK=$(ssh -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "lsblk -dpo NAME,LABEL | grep -i nixos | awk '{print \$1}'" || echo "")

if [[ -n "$USB_DISK" ]]; then
    echo -e "${YELLOW}Installation USB detected: $USB_DISK${NC}"
fi

# Get list of available disks (excluding the USB if detected)
if [[ -n "$USB_DISK" ]]; then
    AVAILABLE_DISKS=$(ssh -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "lsblk -dpno NAME | grep -E '^/dev/(sd|nvme|vd)' | grep -v '$USB_DISK'")
else
    AVAILABLE_DISKS=$(ssh -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "lsblk -dpno NAME | grep -E '^/dev/(sd|nvme|vd)'")
fi

# Select disk
DISK_COUNT=$(echo "$AVAILABLE_DISKS" | wc -l)

if [[ "$DISK_COUNT" -eq 1 ]]; then
    DISK=$(echo "$AVAILABLE_DISKS" | head -1)
    echo -e "${GREEN}Disk to install on: $DISK${NC}"
    DISK_INFO=$(ssh -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "lsblk -dpo SIZE,MODEL $DISK" | tail -1)
    echo -e "  Size/Model: $DISK_INFO"
else
    echo -e "${YELLOW}Multiple disks available:${NC}"
    echo "$AVAILABLE_DISKS" | nl
    echo ""
    read -rp "$(echo -e "${YELLOW}Which disk to install on? (e.g.: /dev/sda):${NC} ")" DISK
fi

echo ""
read -rp "$(echo -e "${YELLOW}Is $DISK the correct disk for NixOS installation? [y/N]:${NC} ")" confirm_disk
if [[ ! "$confirm_disk" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Enter the correct disk (e.g.: /dev/sda, /dev/nvme0n1):${NC}"
    read -rp "Disk: " DISK
fi

echo -e "${GREEN}✓ Selected disk: $DISK${NC}"

# Confirm installation
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  WARNING: This will ERASE ALL contents on disk $DISK       ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Continue with the installation? [y/N]:${NC} ")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# Update disk in configuration if different
CURRENT_DISK=$(grep 'device = ' "$PROJECT_DIR/hosts/default/hardware-configuration.nix" | sed 's/.*"\(.*\)".*/\1/' | head -1)
if [[ "$DISK" != "$CURRENT_DISK" ]]; then
    echo -e "${YELLOW}Updating disk configuration to $DISK...${NC}"
    sed -i "s|device = .*|device = \"$DISK\";|" "$PROJECT_DIR/hosts/default/hardware-configuration.nix"
fi

# Verify that server SSH keys exist
SERVER_KEY_DIR="$PROJECT_DIR/secrets/server-keys"
if [[ ! -f "$SERVER_KEY_DIR/ssh_host_ed25519_key" ]]; then
    echo -e "${RED}Error: Server SSH keys not found${NC}"
    echo "Run first: ./scripts/setup.sh"
    exit 1
fi

# Run nixos-anywhere
echo ""
echo -e "${BLUE}=== Starting installation with nixos-anywhere ===${NC}"
echo ""

cd "$PROJECT_DIR"

# Create temporary directory for extra-files
EXTRA_FILES=$(mktemp -d)
mkdir -p "$EXTRA_FILES/etc/ssh"
cp "$SERVER_KEY_DIR/ssh_host_ed25519_key" "$EXTRA_FILES/etc/ssh/"
cp "$SERVER_KEY_DIR/ssh_host_ed25519_key.pub" "$EXTRA_FILES/etc/ssh/"
chmod 600 "$EXTRA_FILES/etc/ssh/ssh_host_ed25519_key"

nix run github:nix-community/nixos-anywhere -- \
    --flake .#homelab \
    --target-host "$SSH_USER@$SERVER_IP" \
    --build-on-remote \
    --extra-files "$EXTRA_FILES" \
    --phases "kexec,disko,install,reboot"

# Clean up
rm -rf "$EXTRA_FILES"

ADMIN_USER=$(grep 'adminUser =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

echo ""
echo -e "${YELLOW}Waiting for the server to reboot...${NC}"
sleep 10
for i in $(seq 1 30); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$ADMIN_USER@$SERVER_IP" "echo ok" &>/dev/null; then
        echo -e "${GREEN}✓ Server accessible${NC}"
        break
    fi
    echo "Waiting for SSH... ($i/30)"
    sleep 10
done

if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$ADMIN_USER@$SERVER_IP" "echo ok" &>/dev/null; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Installation completed!                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "The server is not responding via SSH yet. Wait and connect manually:"
    echo -e "  ${GREEN}ssh $ADMIN_USER@$SERVER_IP${NC}"
    exit 0
fi

echo -e "${YELLOW}Waiting for services to start...${NC}"
for i in $(seq 1 60); do
    JOBS=$(ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$SERVER_IP" "sudo systemctl list-jobs --no-pager 2>/dev/null | grep -c 'running\|waiting'" 2>/dev/null || echo "99")
    if [ "$JOBS" -le 1 ]; then
        echo -e "${GREEN}✓ Services started${NC}"
        break
    fi
    echo "Pending services: $JOBS ($i/60)"
    sleep 10
done

# Verify K3s
echo -e "${YELLOW}Verifying K3s...${NC}"
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$SERVER_IP" "sudo k3s kubectl get nodes" &>/dev/null; then
        echo -e "${GREEN}✓ K3s running${NC}"
        ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$SERVER_IP" "sudo k3s kubectl get nodes"
        break
    fi
    echo "Waiting for K3s... ($i/30)"
    sleep 10
done

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Installation completed!                         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Connect with:"
echo -e "  ${GREEN}ssh $ADMIN_USER@$SERVER_IP${NC}"
echo ""
echo "To see the progress of Kubernetes services:"
echo -e "  ${GREEN}sudo systemctl list-jobs --no-pager${NC}"
echo -e "  ${GREEN}sudo k3s kubectl get pods -A${NC}"
echo ""
