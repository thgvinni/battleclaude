# Using Claude Code with Google Vertex AI

This devcontainer is pre-configured to work with Google Cloud Vertex AI instead of the direct Anthropic API.

## Prerequisites

1. **Google Cloud Project** with Vertex AI enabled
2. **Google Cloud SDK** installed on your host machine
3. **IAM Permissions**: Your account needs `roles/aiplatform.user` role

## Setup Instructions

### 1. Authenticate with Google Cloud (on your host machine)

Before opening the devcontainer, authenticate with Google Cloud:

```bash
# Login to Google Cloud
gcloud auth login

# Set your project ID
gcloud config set project YOUR-PROJECT-ID

# Create application default credentials (required for Claude Code)
gcloud auth application-default login

# Enable Vertex AI API
gcloud services enable aiplatform.googleapis.com
```

### 2. Set Environment Variables

Create a `.env` file in your project root (this file is gitignored by default):

```bash
# Required for Vertex AI
CLAUDE_CODE_USE_VERTEX=1
ANTHROPIC_VERTEX_PROJECT_ID=your-gcp-project-id
CLOUD_ML_REGION=us-central1

# Optional: If using a different region
# CLOUD_ML_REGION=europe-west4
```

Or export them in your shell before opening VS Code:

```bash
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID=your-gcp-project-id
export CLOUD_ML_REGION=us-central1
```

### 3. Open DevContainer

1. Open the project in VS Code
2. When prompted, click "Reopen in Container"
3. Wait for the container to build

Your host machine's `~/.config/gcloud` directory is automatically mounted into the container, so your credentials will be available.

### 4. Verify Setup

Inside the devcontainer terminal:

```bash
# Check gcloud is authenticated
gcloud auth list

# Check your project is set
gcloud config get-value project

# Start Claude Code (it will use Vertex AI automatically)
claude
```

## Available Regions

Claude on Vertex AI is available in these regions:
- `us-central1` (Iowa)
- `us-east5` (Columbus)
- `europe-west1` (Belgium)
- `europe-west4` (Netherlands)
- `asia-southeast1` (Singapore)

Update `CLOUD_ML_REGION` to match your preferred region.

## How It Works

When you set `CLAUDE_CODE_USE_VERTEX=1`, Claude Code automatically:
- Uses Google Cloud authentication instead of Anthropic API keys
- Routes all requests through Vertex AI
- Disables `/login` and `/logout` commands (uses gcloud auth)
- Uses the project ID from `ANTHROPIC_VERTEX_PROJECT_ID`

## Firewall Configuration

The devcontainer firewall automatically whitelists:
- `aiplatform.googleapis.com` - Vertex AI API
- `oauth2.googleapis.com` - Google OAuth
- `accounts.google.com` - Google authentication

## Troubleshooting

### "Permission denied" errors

Your account needs the AI Platform User role:

```bash
gcloud projects add-iam-policy-binding YOUR-PROJECT-ID \
  --member="user:YOUR-EMAIL@example.com" \
  --role="roles/aiplatform.user"
```

### "API not enabled" errors

Enable the Vertex AI API:

```bash
gcloud services enable aiplatform.googleapis.com
```

### Credentials not found in container

Ensure your host machine has authenticated:

```bash
gcloud auth application-default login
```

Check that `~/.config/gcloud` exists on your host machine and contains credentials.

### Wrong project selected

Set the project explicitly:

```bash
export ANTHROPIC_VERTEX_PROJECT_ID=your-correct-project-id
```

Or inside the container:

```bash
gcloud config set project your-correct-project-id
```

### Region not available

Verify your region supports Claude on Vertex AI:

```bash
gcloud ai models list --region=us-central1 | grep claude
```

## Cost Considerations

Vertex AI pricing differs from direct Anthropic API:
- Charges are billed through your Google Cloud account
- Pricing may vary by region
- Check [Vertex AI pricing](https://cloud.google.com/vertex-ai/pricing) for current rates

## Switching Between Direct API and Vertex AI

To switch back to direct Anthropic API:

1. Set `CLAUDE_CODE_USE_VERTEX=0` or unset the variable
2. Remove Vertex AI environment variables
3. Run `claude` and use `/login` with your Anthropic API key

## Additional Resources

- [Claude on Vertex AI Documentation](https://docs.anthropic.com/en/api/claude-on-vertex-ai)
- [Vertex AI Pricing](https://cloud.google.com/vertex-ai/pricing)
- [Google Cloud SDK Documentation](https://cloud.google.com/sdk/docs)
- [Claude Code Vertex AI Guide](https://docs.claude.com/en/docs/claude-code/google-vertex-ai)
