#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# Enhanced logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

debug_env() {
    log "Environment check:"
    log "  GH_TOKEN is set: $([ -n "${GH_TOKEN:-}" ] && echo "YES (length: ${#GH_TOKEN})" || echo "NO")"
    log "  gh command available: $(command -v gh >/dev/null 2>&1 && echo "YES" || echo "NO")"
    log "  Running as user: $(whoami)"
    log "  UID: $(id -u)"
}

# Run environment debug
debug_env

# 1. Extract Docker DNS info BEFORE any flushing
log "Extracting Docker DNS rules..."
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
log "Flushing existing firewall rules..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    log "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    log "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Allow inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# Allow outbound SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Allow inbound SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Temporarily allow HTTPS for fetching IPs (will be restricted later)
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --sport 443 -m state --state ESTABLISHED -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
log "Fetching GitHub IP ranges..."

# Use GH_TOKEN if available, otherwise fall back to gh CLI
if [ -n "${GH_TOKEN:-}" ]; then
    log "Using GH_TOKEN for GitHub API request..."
    gh_ranges=$(curl -s -H "Authorization: token $GH_TOKEN" https://api.github.com/meta)
    if [ $? -ne 0 ]; then
        error "Failed to fetch GitHub meta with GH_TOKEN"
        exit 1
    fi
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    log "Using authenticated GitHub API request via gh CLI..."
    gh_ranges=$(gh api /meta)
    if [ $? -ne 0 ]; then
        error "Failed to fetch GitHub meta with gh CLI"
        exit 1
    fi
else
    error "Neither GH_TOKEN is set nor gh CLI is authenticated"
    error "GH_TOKEN length: ${#GH_TOKEN:-0}"
    error "Please ensure GH_TOKEN is passed through sudo with --preserve-env=GH_TOKEN"
    exit 1
fi

if [ -z "$gh_ranges" ]; then
    error "Failed to fetch GitHub IP ranges"
    exit 1
fi

if echo "$gh_ranges" | jq -e '.message' >/dev/null 2>&1; then
    error "GitHub API returned an error: $(echo "$gh_ranges" | jq -r '.message')"
    error "This is often due to rate limiting or invalid token"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.hooks and .pages and .git' >/dev/null; then
    error "GitHub API response missing required fields"
    error "Response keys: $(echo "$gh_ranges" | jq -r 'keys | join(", ")')"
    exit 1
fi

log "Processing GitHub IPs..."
gh_ip_count=0
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        error "Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    log "  Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr"
    ((gh_ip_count++))
done < <(echo "$gh_ranges" | jq -r '(.hooks + .web + .api + .git + .pages + .actions + .dependabot + .packages)[]' | sort -u | aggregate -q)
log "Added $gh_ip_count GitHub IP ranges"

# Resolve and add other allowed domains
log "Resolving additional allowed domains..."
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    "aiplatform.googleapis.com" \
    "oauth2.googleapis.com" \
    "accounts.google.com"; do
    log "  Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        error "Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            error "Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        log "    Adding $ip for $domain"
        ipset add allowed-domains "$ip"
    done < <(echo "$ips")
done

# Get host IP from default route
log "Detecting host network..."
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    error "Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
log "Host network detected as: $HOST_NETWORK"

# Now that we have all IPs, flush the temporary rules and set up final firewall
log "Setting up final firewall rules..."
iptables -F INPUT
iptables -F OUTPUT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Re-add essential rules
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

log "Firewall configuration complete"
log "Verifying firewall rules..."

# Test that blocked sites are actually blocked
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    error "Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    log "✓ Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access still works
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    error "Firewall verification failed - unable to reach https://api.github.com"
    error "This suggests the GitHub IP ranges may not be correctly configured"
    exit 1
else
    log "✓ Firewall verification passed - able to reach https://api.github.com as expected"
fi

log "Firewall initialization completed successfully"
