# GCP Cloud Run deployment for org-agenda-api

# Enable required APIs
resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

# Cloud Run service
resource "google_cloud_run_v2_service" "org_agenda_api" {
  name     = var.service_name
  location = var.region

  depends_on = [google_project_service.run]

  template {
    containers {
      image = var.container_image

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
      }

      ports {
        container_port = 80
      }

      # Git sync configuration
      env {
        name  = "GIT_SYNC_REPOSITORY"
        value = var.git_sync_repository
      }
      env {
        name  = "GIT_SSH_PRIVATE_KEY"
        value = var.git_ssh_private_key
      }
      env {
        name  = "GIT_SYNC_INTERVAL"
        value = tostring(var.git_sync_interval)
      }
      env {
        name  = "GIT_SYNC_NEW_FILES"
        value = "true"
      }
      env {
        name  = "GIT_USER_EMAIL"
        value = var.git_user_email
      }
      env {
        name  = "GIT_USER_NAME"
        value = var.git_user_name
      }

      # Auth configuration (if provided)
      dynamic "env" {
        for_each = var.auth_user != "" ? [1] : []
        content {
          name  = "AUTH_USER"
          value = var.auth_user
        }
      }
      dynamic "env" {
        for_each = var.auth_password != "" ? [1] : []
        content {
          name  = "AUTH_PASSWORD"
          value = var.auth_password
        }
      }

      # Custom elisp (if provided)
      dynamic "env" {
        for_each = var.custom_elisp != "" ? [1] : []
        content {
          name  = "ORG_API_CUSTOM_ELISP_CONTENT"
          value = var.custom_elisp
        }
      }
    }

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

# IAM policy to allow public access (if enabled)
resource "google_cloud_run_v2_service_iam_member" "public" {
  count = var.allow_unauthenticated ? 1 : 0

  location = google_cloud_run_v2_service.org_agenda_api.location
  name     = google_cloud_run_v2_service.org_agenda_api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
