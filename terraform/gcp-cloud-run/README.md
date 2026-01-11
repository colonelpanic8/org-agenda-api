# GCP Cloud Run Deployment

Deploy org-agenda-api to Google Cloud Run using Terraform.

## Prerequisites

1. [GCP account](https://cloud.google.com) with a project
2. [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed and authenticated
3. [Terraform](https://terraform.io) >= 1.0
4. Container image pushed to a registry accessible by Cloud Run

## Pushing the Container Image

You can use GitHub Container Registry, Google Artifact Registry, or Docker Hub.

### Using GitHub Container Registry:
```bash
# Build the container
nix build .#container

# Load and tag
docker load < result
docker tag org-agenda-api:latest ghcr.io/YOUR_USERNAME/org-agenda-api:latest

# Push
docker push ghcr.io/YOUR_USERNAME/org-agenda-api:latest
```

### Using Google Artifact Registry:
```bash
# Enable Artifact Registry API
gcloud services enable artifactregistry.googleapis.com

# Create a repository
gcloud artifacts repositories create org-agenda-api \
  --repository-format=docker \
  --location=us-central1

# Configure Docker auth
gcloud auth configure-docker us-central1-docker.pkg.dev

# Build, tag, and push
nix build .#container
docker load < result
docker tag org-agenda-api:latest us-central1-docker.pkg.dev/YOUR_PROJECT/org-agenda-api/org-agenda-api:latest
docker push us-central1-docker.pkg.dev/YOUR_PROJECT/org-agenda-api/org-agenda-api:latest
```

## Deployment

1. Authenticate with GCP:
   ```bash
   gcloud auth application-default login
   ```

2. Copy the example variables file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your values:
   - `project_id`: Your GCP project ID
   - `service_name`: Name for the Cloud Run service
   - `git_sync_repository`: Your org-files git repository URL
   - `git_ssh_private_key`: SSH private key for git access
   - `auth_user` / `auth_password`: HTTP basic auth credentials

4. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

5. The service URL will be output after deployment.

## Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `project_id` | Yes | GCP project ID |
| `service_name` | Yes | Cloud Run service name |
| `git_sync_repository` | Yes | Git repo URL to sync |
| `git_ssh_private_key` | Yes | SSH private key |
| `auth_user` | No | HTTP basic auth username |
| `auth_password` | No | HTTP basic auth password |
| `region` | No | GCP region (default: us-central1) |
| `container_image` | No | Container image to deploy |
| `cpu` | No | CPU allocation (default: 1) |
| `memory` | No | Memory allocation (default: 512Mi) |
| `min_instances` | No | Min instances, 0 for scale-to-zero (default: 0) |
| `max_instances` | No | Max instances (default: 1) |
| `custom_elisp` | No | Inline elisp to evaluate on startup |
| `allow_unauthenticated` | No | Allow public access (default: true) |

## Scale to Zero

By default, `min_instances = 0` enables scale-to-zero. The service will shut down when idle and start on first request (cold start ~10-30s for Emacs).

Set `min_instances = 1` to keep an instance always running.

## Destroying

```bash
terraform destroy
```
