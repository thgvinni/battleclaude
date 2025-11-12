#!/bin/bash
#
# YOLO Mode Enabler for Claude Code
#
# This script enables "dangerously skip permissions" mode by:
# 1. Verifying gh CLI authentication
# 2. Initializing the network firewall with GitHub IP restrictions
# 3. Configuring Claude Code to skip permission prompts
#
# WARNING: Only use this in trusted repositories!
#

set -euo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[YOLO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[YOLO] WARNING:${NC} $*"
}

error() {
    echo -e "${RED}[YOLO] ERROR:${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[YOLO] ✓${NC} $*"
}

# =============================================================================
# STEP 1: CHECK GH AUTHENTICATION
# =============================================================================

log "Step 1/3: Checking GitHub CLI authentication..."

if ! command -v gh >/dev/null 2>&1; then
    error "gh CLI is not installed"
    error "This should not happen in the devcontainer"
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    error "GitHub CLI is not authenticated"
    echo ""
    echo "To fix this, run:"
    echo ""
    echo "  ${BLUE}gh auth login${NC}"
    echo ""
    echo "Then run yolo.sh again."
    exit 1
fi

# Get the authenticated user
GH_USER=$(gh api user -q '.login' 2>/dev/null || echo "unknown")
success "Authenticated as: $GH_USER"

# =============================================================================
# STEP 2: INITIALIZE FIREWALL
# =============================================================================

log "Step 2/3: Initializing network firewall..."

if [ ! -f /usr/local/bin/init-firewall.sh ]; then
    error "Firewall script not found at /usr/local/bin/init-firewall.sh"
    exit 1
fi

# Run firewall initialization with gh CLI authentication
# The firewall script will use gh CLI to fetch GitHub IP ranges
if ! sudo -E /usr/local/bin/init-firewall.sh; then
    error "Firewall initialization failed"
    error "Check the logs above for details"
    exit 1
fi

success "Firewall initialized successfully"

# =============================================================================
# STEP 3: CONFIGURE CLAUDE CODE PERMISSIONS
# =============================================================================

log "Step 3/3: Configuring Claude Code to skip permissions..."

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"
SETTINGS_FILE="$CLAUDE_CONFIG_DIR/settings.local.json"

# Create .claude directory if it doesn't exist
if [ ! -d "$CLAUDE_CONFIG_DIR" ]; then
    mkdir -p "$CLAUDE_CONFIG_DIR"
    chown -R "$USER:$USER" "$CLAUDE_CONFIG_DIR"
fi

# Create or update settings.local.json
cat > "$SETTINGS_FILE" <<EOF
{
  "dangerouslySkipPermissions": true
}
EOF

# Set proper permissions
chmod 644 "$SETTINGS_FILE"
if [ "$USER" != "root" ]; then
    chown "$USER:$USER" "$SETTINGS_FILE"
fi

success "Claude Code configured for YOLO mode"

# =============================================================================
# SUCCESS MESSAGE
# =============================================================================

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  🚀 YOLO MODE ENABLED                                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Configuration:"
echo "  • Network firewall: ✓ Active (GitHub IPs only)"
echo "  • Permissions: ✓ Skipped (dangerous mode)"
echo "  • Config file: $SETTINGS_FILE"
echo ""
echo -e "${YELLOW}⚠️  SECURITY WARNING${NC}"
echo ""
echo "  You are running Claude Code with --dangerously-skip-permissions."
echo "  Claude can execute ANY command without asking for confirmation."
echo ""
echo "  Only use this mode in:"
echo "  • Trusted repositories you control"
echo "  • Sandboxed environments (like this devcontainer)"
echo "  • Repositories with active firewall restrictions"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo ""
echo "  1. Reload VS Code window (Cmd+Shift+P → 'Reload Window')"
echo "  2. Claude Code will now run without permission prompts"
echo ""
echo -e "${BLUE}To disable YOLO mode:${NC}"
echo ""
echo "  rm $SETTINGS_FILE"
echo "  # Then reload VS Code window"
echo ""
