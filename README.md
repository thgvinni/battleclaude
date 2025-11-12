# BattleClaude DevContainer

A security-hardened development environment for Claude Code with optional firewall protection and YOLO mode for trusted repositories.

## Table of Contents

- [Quick Start](#quick-start)
- [YOLO Mode (Skip Permissions)](#yolo-mode-skip-permissions)
- [Setup](#setup)
  - [Prerequisites](#prerequisites)
  - [GitHub CLI Authentication](#github-cli-authentication)
- [Architecture](#architecture)
- [Network Security](#network-security)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

**Default mode (Safe):**

1. **Open this project in VS Code**
2. **Click "Reopen in Container"** when prompted
3. **Wait for the container to build** (first time takes 3-5 minutes)
4. Claude Code will ask for permission for each tool execution

**YOLO mode (for trusted repos only):**

See [YOLO Mode](#yolo-mode-skip-permissions) below to enable dangerous mode with firewall protection.

---

## YOLO Mode (Skip Permissions)

### What is YOLO Mode?

YOLO Mode enables Claude Code to run with `--dangerously-skip-permissions`, allowing Claude to execute **any command without asking**. This is combined with a network firewall to restrict outbound connections to approved services only.

### ⚠️ Security Warning

**Only use YOLO mode when:**
- ✅ You completely trust the repository
- ✅ You're working in a sandboxed environment (like this devcontainer)
- ✅ You understand Claude will have unrestricted command execution
- ❌ **NEVER** use in production environments
- ❌ **NEVER** use with untrusted code

### How to Enable YOLO Mode

**Step 1: Authenticate with GitHub**

```bash
# Inside the devcontainer terminal
gh auth login
```

Follow the prompts to authenticate (browser or token).

**Step 2: Run the YOLO script**

```bash
yolo.sh
```

The script will:
1. ✓ Verify your GitHub authentication
2. ✓ Initialize network firewall (GitHub IPs only)
3. ✓ Configure Claude Code to skip permissions
4. ✓ Create `.devcontainer/.claude/settings.local.json`

**Step 3: Reload VS Code**

- Command Palette (Cmd/Ctrl+Shift+P)
- Select: `Developer: Reload Window`

Claude Code will now run without permission prompts!

### How YOLO Mode Works

```
┌─────────────────────────────────────────────────┐
│ Claude Code (--dangerously-skip-permissions)    │
│ ✓ Executes commands instantly                   │
│ ✓ No permission prompts                         │
└─────────────────┬───────────────────────────────┘
                  │
                  ↓
┌─────────────────────────────────────────────────┐
│ Network Firewall (iptables + ipset)             │
│ ✓ Allows: GitHub, npm, Anthropic, Google Cloud  │
│ ✗ Blocks: All other outbound connections        │
└─────────────────────────────────────────────────┘
```

### How to Disable YOLO Mode

```bash
# Remove the settings file
rm ~/.claude/settings.local.json

# Or from host (if volume mounted)
rm .devcontainer/.claude/settings.local.json

# Reload VS Code window
```

Claude Code will return to normal mode with permission prompts.

### Files Created

```
.devcontainer/
└── .claude/
    ├── .gitignore              # Ignores settings.local.json
    └── settings.local.json     # Your YOLO mode config (gitignored)
```

Each developer chooses their own permission level - the settings file is never committed to git.

---

## Setup

### Prerequisites

- **Docker Desktop** or **Rancher Desktop** running
- **VS Code** with the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
- **macOS**, Linux, or Windows with WSL2

### GitHub CLI Authentication

GitHub CLI authentication is **required for YOLO mode** to fetch GitHub IP ranges for the firewall.

#### When to authenticate:

- ✅ You want to use YOLO mode (dangerously skip permissions)
- ✅ The devcontainer will work fine without authentication (safe mode)

#### How to authenticate:

**Inside the devcontainer**, run:

```bash
gh auth login
```

Follow the prompts:
1. Choose **GitHub.com**
2. Choose **HTTPS** protocol
3. Authenticate via **browser** or **paste token**

The authentication is stored in `~/.config/gh` (mounted from your host machine), so you only need to do this once.

**Verify authentication:**

```bash
gh auth status
```

You should see: ✓ Logged in to github.com

---

## Architecture

### DevContainer Structure

```
.devcontainer/
├── devcontainer.json    # VS Code devcontainer configuration
├── Dockerfile           # Container image definition
└── init-firewall.sh     # Network firewall initialization
```

### Container Features

- **Base Image**: Node.js 20 (Debian Bookworm)
- **User**: `node` (non-root, UID 1000)
- **Shell**: Zsh with oh-my-zsh and powerlevel10k
- **Editor**: nano (default), vim also available
- **Tools**: git, gh, gcloud, fzf, delta, and more

### Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|----------------|---------|
| Project root | `/workspace` | Your code |
| `~/.config/gcloud` | `/home/node/.config/gcloud` | Google Cloud CLI config |
| `~/.config/gh` | `/home/node/.config/gh` | GitHub CLI config |
| Docker volume | `/commandhistory` | Persistent bash/zsh history |
| Docker volume | `/home/node/.claude` | Claude Code configuration |

---

## Network Security

### Firewall Overview

The devcontainer uses **iptables** with a **default-deny policy**:

- ✅ **Allowed**: GitHub, npm, Anthropic, Google Cloud, VS Code services
- ❌ **Blocked**: All other outbound connections

### Allowed Domains

The firewall allows connections to:

**GitHub** (via IP ranges from `/meta` API):
- `github.com` (web, API, git)
- `raw.githubusercontent.com`
- GitHub Pages

**Development Services**:
- `registry.npmjs.org` - npm packages
- `api.anthropic.com` - Claude API
- `aiplatform.googleapis.com` - Vertex AI
- `marketplace.visualstudio.com` - VS Code extensions
- `vscode.blob.core.windows.net` - VS Code assets

**Telemetry** (optional):
- `sentry.io`
- `statsig.anthropic.com`

### How the Firewall Works

1. **Phase 1**: Save Docker DNS rules and flush existing firewall
2. **Phase 2**: Restore Docker internal DNS (127.0.0.11)
3. **Phase 3**: Set temporary permissive rules for IP collection
4. **Phase 4**: Fetch GitHub IP ranges and resolve allowed domains
5. **Phase 5**: Detect host network (for Docker host access)
6. **Phase 6**: Apply final restrictive rules with ipset
7. **Phase 7**: Verify firewall (test blocked/allowed sites)

### Customizing Allowed Domains

Edit `.devcontainer/init-firewall.sh` and add domains to the `ALLOWED_DOMAINS` array:

```bash
ALLOWED_DOMAINS=(
    "registry.npmjs.org"
    "your-domain.com"  # Add your domain here
    # ... other domains
)
```

Then rebuild the container.

---

## Troubleshooting

### Container fails to start with "GitHub API rate limit exceeded"

**Cause**: You've hit the 60 requests/hour limit for unauthenticated API access.

**Solutions**:
1. Wait for the rate limit to reset (check: `curl -s https://api.github.com/rate_limit`)
2. Set up a GitHub token (see [GitHub Token Setup](#github-token-optional-but-recommended))

### Container fails with "Failed to authenticate with GitHub"

**Old behavior** (if you see this with the updated script, you have an old version):

The firewall script now works **without** authentication and falls back automatically. Update your script:

```bash
git pull origin main
# Or manually copy the new init-firewall.sh
```

### "Unable to reach npm registry" during builds

**Cause**: npm registry IPs may have changed or DNS resolution failed.

**Solutions**:
1. Rebuild the container (IPs are fetched fresh on each build)
2. Check if `registry.npmjs.org` is resolvable: `dig registry.npmjs.org`
3. Temporarily disable the firewall for debugging (see below)

### Debugging: Disable firewall temporarily

**Option 1**: Comment out the firewall in `devcontainer.json`:

```json
{
  // "postStartCommand": "sudo -E HOME=/home/node /usr/local/bin/init-firewall.sh",
  "postStartCommand": "echo 'Firewall disabled'"
}
```

**Option 2**: Reset firewall inside the container:

```bash
# Inside the container
sudo iptables -P INPUT ACCEPT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -F
```

### GH_TOKEN is set but still using unauthenticated API

**Cause**: VS Code doesn't inherit environment variables from your terminal.

**Check**:
```bash
# Inside the container
echo $GH_TOKEN
```

If empty, VS Code didn't receive the token.

**Solutions**:
- macOS: Use `launchctl setenv` (see [Option B](#github-token-optional-but-recommended))
- Linux: Ensure token is in `~/.zshenv` or similar early-loaded profile
- All: Launch VS Code from terminal where `GH_TOKEN` is set

### "Permission denied" errors in the container

**Cause**: File ownership mismatch between host and container.

**Check**:
```bash
# On host
id -u  # Should be 502 on macOS

# Inside container
id -u node  # Should be 1000
```

**Solution**: The devcontainer handles this automatically for workspace files. For mounted volumes (like `~/.config/gh`), the container can read them but ownership shows as UID 502.

### Firewall blocks required service

**Symptom**: A service you need is blocked by the firewall.

**Solution**: Add the domain to `ALLOWED_DOMAINS` in `init-firewall.sh`:

```bash
ALLOWED_DOMAINS=(
    # ... existing domains ...
    "your-required-service.com"
)
```

Rebuild the container.

### How to check current rate limit status

```bash
# Check GitHub API rate limit
curl -s https://api.github.com/rate_limit | jq '.rate'

# With authentication
curl -s -H "Authorization: token $GH_TOKEN" https://api.github.com/rate_limit | jq '.rate'
```

Output:
```json
{
  "limit": 60,        // or 5000 with token
  "remaining": 45,
  "reset": 1699564800,
  "used": 15
}
```

---

## Development Workflow

### First-time setup

```bash
# 1. Clone the repository
git clone <your-repo-url>
cd battleclaude

# 2. (Optional) Set up GitHub token
export GH_TOKEN="ghp_your_token_here"

# 3. Open in VS Code
code .

# 4. Click "Reopen in Container" when prompted
```

### Daily workflow

```bash
# Open the project
code /path/to/battleclaude

# Container starts automatically with your previous state preserved
```

### Rebuilding the container

When you update `Dockerfile`, `devcontainer.json`, or `init-firewall.sh`:

1. **Command Palette** (Cmd+Shift+P / Ctrl+Shift+P)
2. **Dev Containers: Rebuild Container**
3. Wait for rebuild (faster than first build, uses cache)

---

## Security Best Practices

### ✅ Do

- Keep your GitHub token private (never commit to git)
- Use fine-grained tokens with minimal scopes
- Rotate tokens regularly
- Review firewall logs: `sudo iptables -L -n -v`
- Only add trusted domains to the allowlist

### ❌ Don't

- Share tokens between developers (each developer creates their own)
- Hardcode tokens in `devcontainer.json` (use environment variables)
- Disable the firewall without understanding the security implications
- Add broad IP ranges to the allowlist

---

## Contributing

When adding new required services:

1. Add the domain to `ALLOWED_DOMAINS` in `init-firewall.sh`
2. Test that the firewall still blocks unwanted traffic
3. Document the service and why it's needed
4. Update this README

---

## License

[Your license here]

---

## Support

For issues specific to this devcontainer setup:
- Check [Troubleshooting](#troubleshooting) above
- Review logs: `.devcontainer/init-firewall.sh` output during startup
- Open an issue with the full error message and setup details

For Claude Code issues:
- See https://code.claude.com/docs
- GitHub: https://github.com/anthropics/claude-code
