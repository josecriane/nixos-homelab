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

echo -e "${BLUE}=== NixOS Server - Update configuration ===${NC}"
echo ""

# Read configuration
SERVER_IP=$(grep 'serverIP =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
ADMIN_USER=$(grep 'adminUser =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

echo -e "${GREEN}Server:${NC} $ADMIN_USER@$SERVER_IP"
echo ""

# Verify connection
echo -e "${YELLOW}Verifying connection...${NC}"
if ! ssh -o ConnectTimeout=5 "$ADMIN_USER@$SERVER_IP" "echo ok" &>/dev/null; then
    echo "Cannot connect to the server."
    exit 1
fi
echo -e "${GREEN}✓ Connection OK${NC}"

# Update flake
echo -e "${YELLOW}Updating flake.lock...${NC}"
cd "$PROJECT_DIR"
nix flake update

# Clean marker files to force service reconfiguration
echo -e "${YELLOW}Cleaning markers to reconfigure services...${NC}"
ssh "$ADMIN_USER@$SERVER_IP" "sudo rm -f /var/lib/*-setup-done /var/lib/*-config-done" 2>/dev/null || true
echo -e "${GREEN}✓ Markers cleaned${NC}"

# Remote rebuild
echo -e "${YELLOW}Applying configuration...${NC}"
set +e  # Allow continuation if rebuild fails partially
nixos-rebuild switch \
    --flake .#homelab \
    --target-host "$ADMIN_USER@$SERVER_IP" \
    --sudo \
    --impure
REBUILD_EXIT=$?
set -e

if [ $REBUILD_EXIT -ne 0 ] && [ $REBUILD_EXIT -ne 4 ]; then
    echo -e "${RED}Rebuild error (code $REBUILD_EXIT)${NC}"
    exit $REBUILD_EXIT
fi

if [ $REBUILD_EXIT -eq 4 ]; then
    echo -e "${YELLOW}⚠ Rebuild completed with warnings (systemd-networkd-wait-online)${NC}"
fi

echo ""
echo -e "${GREEN}✓ Configuration updated${NC}"
