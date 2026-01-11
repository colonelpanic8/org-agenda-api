# Fly.io Deployment

Deploy org-agenda-api to Fly.io using Terraform.

## Prerequisites

1. [Fly.io account](https://fly.io)
2. [flyctl CLI](https://fly.io/docs/hands-on/install-flyctl/) installed and authenticated
3. [Terraform](https://terraform.io) >= 1.0
4. Container image pushed to a registry (see below)

## Pushing the Container Image

Build and push the container to a registry (e.g., GitHub Container Registry):

```bash
# Build the container
nix build .#container

# Load and tag
docker load < result
docker tag org-agenda-api:latest ghcr.io/YOUR_USERNAME/org-agenda-api:latest

# Push (requires docker login to ghcr.io)
docker push ghcr.io/YOUR_USERNAME/org-agenda-api:latest
```

## Deployment

1. Copy the example variables file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your values:
   - `app_name`: Unique name for your Fly.io app
   - `git_sync_repository`: Your org-files git repository URL
   - `git_ssh_private_key`: SSH private key for git access
   - `auth_user` / `auth_password`: HTTP basic auth credentials

3. Set your Fly.io API token:
   ```bash
   export FLY_API_TOKEN=$(flyctl auth token)
   ```

4. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

5. Access your API at `https://YOUR_APP_NAME.fly.dev`

## Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `app_name` | Yes | Fly.io application name |
| `git_sync_repository` | Yes | Git repo URL to sync |
| `git_ssh_private_key` | Yes | SSH private key |
| `auth_user` | No | HTTP basic auth username |
| `auth_password` | No | HTTP basic auth password |
| `region` | No | Fly.io region (default: ord) |
| `container_image` | No | Container image to deploy |
| `vm_size` | No | VM size (default: shared-cpu-1x) |
| `vm_memory` | No | Memory in MB (default: 512) |
| `git_sync_interval` | No | Sync interval in seconds (default: 60) |
| `custom_elisp` | No | Inline elisp to evaluate on startup |

## Custom Elisp

You can pass custom elisp code to configure org-capture templates or other settings:

```hcl
custom_elisp = <<-EOT
  (setq org-agenda-api-capture-templates
    '(("todo"
       :name "Todo"
       :template ("t" "Todo" entry (file "/data/org/inbox.org")
                  "* TODO %^{Title}\n%U\n%?")
       :prompts (("Title" :type string :required t)))))
EOT
```

## Destroying

```bash
terraform destroy
```
