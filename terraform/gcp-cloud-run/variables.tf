# Required variables

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "service_name" {
  description = "Name of the Cloud Run service"
  type        = string
}

variable "git_sync_repository" {
  description = "Git repository URL to sync (e.g., git@github.com:user/org-files.git)"
  type        = string
}

variable "git_ssh_private_key" {
  description = "SSH private key for git repository access"
  type        = string
  sensitive   = true
}

# Authentication (at least one method should be configured)

variable "auth_user" {
  description = "Username for HTTP basic auth"
  type        = string
  default     = ""
}

variable "auth_password" {
  description = "Password for HTTP basic auth"
  type        = string
  sensitive   = true
  default     = ""
}

# Optional configuration

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "container_image" {
  description = "Container image to deploy"
  type        = string
  default     = "ghcr.io/colonelpanic8/org-agenda-api:latest"
}

variable "cpu" {
  description = "CPU allocation (e.g., 1, 2)"
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory allocation (e.g., 512Mi, 1Gi)"
  type        = string
  default     = "512Mi"
}

variable "min_instances" {
  description = "Minimum number of instances (0 for scale to zero)"
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum number of instances"
  type        = number
  default     = 1
}

variable "git_sync_interval" {
  description = "Git sync interval in seconds"
  type        = number
  default     = 60
}

variable "git_user_email" {
  description = "Git user email for commits"
  type        = string
  default     = "org-agenda-api@localhost"
}

variable "git_user_name" {
  description = "Git user name for commits"
  type        = string
  default     = "org-agenda-api"
}

variable "custom_elisp" {
  description = "Custom elisp code to evaluate on startup (inline)"
  type        = string
  default     = ""
}

variable "allow_unauthenticated" {
  description = "Allow unauthenticated access (the app has its own HTTP basic auth)"
  type        = bool
  default     = true
}
