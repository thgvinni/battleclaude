#!/bin/bash
#
# Firewall Initialization Script for Claude Code DevContainer
#
# This script sets up a restrictive firewall that only allows outbound
# connections to approved domains and services.
#
# GitHub Authentication:
#   - REQUIRED: Must have gh CLI authenticated (run: gh auth login)
#   - This script is called by yolo.sh which verifies authentication first
#

set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'        # Stricter word splitting

# =============================================================================
# LOGGING AND ERROR HANDLING
# =============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

warn() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

fatal() {
    error "$@"
    exit 1
}

# Cleanup function for rollback on error
cleanup_on_error() {
    if [ $? -ne 0 ]; then
        error "Script failed, cleaning up..."
        # Reset to permissive state on error
        iptables -P INPUT ACCEPT 2>/dev/null || true
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
        iptables -F 2>/dev/null || true
        ipset destroy allowed-domains 2>/dev/null || true
    fi
}
trap cleanup_on_error EXIT

# =============================================================================
# VALIDATION HELPERS
# =============================================================================

validate_cidr() {
    local cidr="$1"
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# ENVIRONMENT CHECK
# =============================================================================

log "Starting firewall initialization..."
log "Environment check:"
log "  Running as: $(whoami) (UID: $(id -u))"
log "  GH_TOKEN: $([ -n "${GH_TOKEN:-}" ] && echo "SET (length: ${#GH_TOKEN})" || echo "NOT SET")"

# Verify required tools
for tool in iptables ipset dig jq curl aggregate; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        fatal "$tool is not installed"
    fi
done

# =============================================================================
# PHASE 1: SAVE DOCKER DNS AND FLUSH EXISTING RULES
# =============================================================================

log "Phase 1: Saving Docker DNS rules and flushing existing firewall..."

# Extract Docker DNS info BEFORE any flushing (internal Docker DNS at 127.0.0.11)
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush all existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Destroy existing ipsets
ipset destroy allowed-domains 2>/dev/null || true

log "✓ Existing firewall rules flushed"

# =============================================================================
# PHASE 2: RESTORE DOCKER DNS (INTERNAL ONLY)
# =============================================================================

log "Phase 2: Restoring Docker internal DNS resolution..."

if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | while IFS= read -r rule; do
        iptables -t nat $rule || warn "Failed to restore Docker DNS rule: $rule"
    done
    log "✓ Docker DNS rules restored"
else
    log "  No Docker DNS rules to restore"
fi

# =============================================================================
# PHASE 3: SETUP TEMPORARY PERMISSIVE RULES FOR IP COLLECTION
# =============================================================================

log "Phase 3: Setting up temporary rules for IP collection..."

# Set permissive defaults temporarily
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow essential services
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT

log "✓ Temporary permissive rules active"

# =============================================================================
# PHASE 4: CREATE IPSET AND FETCH ALLOWED IP RANGES
# =============================================================================

log "Phase 4: Creating ipset and fetching allowed IP ranges..."

# Create ipset for allowed destinations
if ! ipset create allowed-domains hash:net; then
    fatal "Failed to create ipset"
fi

# -----------------------------------------------------------------------------
# Fetch GitHub IP ranges (requires gh CLI authentication)
# -----------------------------------------------------------------------------

log "Fetching GitHub IP ranges using gh CLI..."

# Use gh CLI (which should be authenticated via yolo.sh)
if ! command -v gh >/dev/null 2>&1; then
    fatal "gh CLI is not installed"
fi

# Fetch GitHub meta information using gh CLI
# Note: gh CLI will use its stored authentication (from gh auth login)
gh_ranges=$(gh api /meta 2>&1) || {
    error "Failed to fetch GitHub IP ranges via gh CLI"
    error ""
    error "This usually means:"
    error "  1. gh CLI is not authenticated"
    error "  2. GitHub API is unreachable"
    error ""
    error "To fix:"
    error "  Run: gh auth login"
    error "  Then run yolo.sh again"
    exit 1
}

# Validate response
if [ -z "$gh_ranges" ]; then
    fatal "GitHub API returned empty response"
fi

# Check for API errors
if echo "$gh_ranges" | jq -e '.message' >/dev/null 2>&1; then
    api_error=$(echo "$gh_ranges" | jq -r '.message')
    error "GitHub API error: $api_error"
    error ""
    error "Try re-authenticating: gh auth login"
    exit 1
fi

# Validate response structure
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    error "GitHub API response missing required fields"
    error "Response keys: $(echo "$gh_ranges" | jq -r 'keys | join(", ")')"
    exit 1
fi

# Add GitHub IP ranges to ipset
log "  Processing GitHub IP ranges..."
gh_ip_count=0

while IFS= read -r cidr; do
    if ! validate_cidr "$cidr"; then
        warn "Skipping invalid CIDR from GitHub: $cidr"
        continue
    fi

    if ipset add allowed-domains "$cidr" 2>/dev/null; then
        gh_ip_count=$((gh_ip_count + 1))
    else
        warn "Failed to add $cidr to ipset"
    fi
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | grep -v ':' | aggregate -q)

log "✓ Added $gh_ip_count GitHub IP ranges (via gh CLI)"

# -----------------------------------------------------------------------------
# Resolve and add other required domains
# -----------------------------------------------------------------------------

log "  Resolving additional required domains..."

ALLOWED_DOMAINS=(
    "registry.npmjs.org"
    "api.anthropic.com"
    "sentry.io"
    "statsig.anthropic.com"
    "statsig.com"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
    "aiplatform.googleapis.com"
    "oauth2.googleapis.com"
    "accounts.google.com"
)

domain_count=0
for domain in "${ALLOWED_DOMAINS[@]}"; do
    ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}')

    if [ -z "$ips" ]; then
        warn "Failed to resolve $domain (skipping)"
        continue
    fi

    while IFS= read -r ip; do
        if ! validate_ip "$ip"; then
            warn "Skipping invalid IP for $domain: $ip"
            continue
        fi

        if ipset add allowed-domains "$ip" 2>/dev/null; then
            domain_count=$((domain_count + 1))
        else
            warn "Failed to add $ip ($domain) to ipset"
        fi
    done < <(echo "$ips")
done

log "✓ Added $domain_count IPs from additional domains"

# =============================================================================
# PHASE 5: DETECT HOST NETWORK
# =============================================================================

log "Phase 5: Detecting host network..."

HOST_IP=$(ip route | grep default | awk '{print $3}')
if [ -z "$HOST_IP" ]; then
    fatal "Failed to detect host IP from default route"
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')

if ! validate_cidr "$HOST_NETWORK"; then
    fatal "Detected invalid host network: $HOST_NETWORK"
fi

log "✓ Host network: $HOST_NETWORK"

# =============================================================================
# PHASE 6: APPLY FINAL RESTRICTIVE FIREWALL RULES
# =============================================================================

log "Phase 6: Applying final restrictive firewall rules..."

# Flush chains to remove temporary rules
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD

# Set default policies to DROP (all traffic denied by default)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# -----------------------------------------------------------------------------
# INPUT chain rules
# -----------------------------------------------------------------------------

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow from host network
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT

# Allow established/related connections (responses to our outbound requests)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# Allow SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# -----------------------------------------------------------------------------
# OUTPUT chain rules (most restrictive)
# -----------------------------------------------------------------------------

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow to host network
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Allow DNS queries
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

# Allow SSH connections
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT

# Allow established/related connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow connections to allowed-domains ipset
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Reject everything else (with clear ICMP response for debugging)
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

log "✓ Restrictive firewall rules applied"

# =============================================================================
# PHASE 7: VERIFICATION
# =============================================================================

log "Phase 7: Verifying firewall configuration..."

# Test 1: Blocked site should be unreachable
log "  Test 1: Verifying blocked sites are unreachable..."
if curl --connect-timeout 3 -sf https://example.com >/dev/null 2>&1; then
    fatal "Firewall verification failed: able to reach blocked site (example.com)"
else
    log "  ✓ Blocked sites are unreachable (example.com)"
fi

# Test 2: GitHub API should be reachable
log "  Test 2: Verifying GitHub API is reachable..."
if ! curl --connect-timeout 5 -sf https://api.github.com/zen >/dev/null 2>&1; then
    error "Firewall verification failed: unable to reach GitHub API"
    error "This suggests the IP ranges may be incorrect or outdated"
    error "GitHub IPs may have changed - try rebuilding the container"
    exit 1
else
    log "  ✓ GitHub API is reachable"
fi

# Test 3: npm registry should be reachable
log "  Test 3: Verifying npm registry is reachable..."
if ! curl --connect-timeout 5 -sf https://registry.npmjs.org >/dev/null 2>&1; then
    warn "npm registry is not reachable - npm installs may fail"
    warn "This could be due to DNS resolution timing or IP changes"
else
    log "  ✓ npm registry is reachable"
fi

# =============================================================================
# SUCCESS
# =============================================================================

log ""
log "============================================"
log "Firewall initialization completed successfully"
log "============================================"
log "Summary:"
log "  - GitHub IPs: $gh_ip_count ranges (via gh CLI)"
log "  - Additional domains: $domain_count IPs"
log "  - Host network: $HOST_NETWORK"
log "  - Default policy: DROP (deny all except allowed)"
log ""

# Disable error trap on success
trap - EXIT
exit 0
