# Fly.io deployment for org-agenda-api

resource "fly_app" "org_agenda_api" {
  name = var.app_name
  org  = "personal"  # Change if using a different org
}

resource "fly_ip" "ipv4" {
  app  = fly_app.org_agenda_api.name
  type = "v4"
}

resource "fly_ip" "ipv6" {
  app  = fly_app.org_agenda_api.name
  type = "v6"
}

resource "fly_machine" "org_agenda_api" {
  app    = fly_app.org_agenda_api.name
  region = var.region
  name   = "${var.app_name}-machine"

  image = var.container_image

  env = merge(
    {
      # Git sync configuration
      GIT_SYNC_REPOSITORY = var.git_sync_repository
      GIT_SSH_PRIVATE_KEY = var.git_ssh_private_key
      GIT_SYNC_INTERVAL   = tostring(var.git_sync_interval)
      GIT_SYNC_NEW_FILES  = "true"
      GIT_USER_EMAIL      = var.git_user_email
      GIT_USER_NAME       = var.git_user_name
    },
    # Auth configuration (only if provided)
    var.auth_user != "" ? {
      AUTH_USER     = var.auth_user
      AUTH_PASSWORD = var.auth_password
    } : {},
    # Custom elisp (only if provided)
    var.custom_elisp != "" ? {
      ORG_API_CUSTOM_ELISP_CONTENT = var.custom_elisp
    } : {}
  )

  services = [
    {
      ports = [
        {
          port     = 443
          handlers = ["tls", "http"]
        },
        {
          port     = 80
          handlers = ["http"]
        }
      ]
      protocol      = "tcp"
      internal_port = 80

      concurrency = {
        type       = "connections"
        hard_limit = 25
        soft_limit = 20
      }
    }
  ]

  cpus     = 1
  memorymb = var.vm_memory
  cputype  = var.vm_size
}
