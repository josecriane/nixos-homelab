#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.nix"

SERVER_IP=$(grep 'serverIP =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
ADMIN_USER=$(grep 'adminUser =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

echo "Connecting to $ADMIN_USER@$SERVER_IP..."
ssh "$ADMIN_USER@$SERVER_IP" "sudo backup-status"
