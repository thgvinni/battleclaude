Pre-requisites on your host machine:
- Ensure you have .devcontainer plugin installed for your IDE
- Docker/Rancher running
- Claude is configured via VertexAI 
- Github CLI is fully configured and gh auth login is done on the host machine before running devcontainer

To make the GH_TOKEN persistent, add this to your ~/.zshrc:

  export GH_TOKEN=$(gh auth token)

  Then reload your shell:
  source ~/.zshrc
