# Required variables

variable "app_name" {
  description = "Name of the Fly.io application"
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
  description = "Fly.io region (see: fly platform regions)"
  type        = string
  default     = "ord"  # Chicago
}

variable "container_image" {
  description = "Container image to deploy"
  type        = string
  default     = "ghcr.io/colonelpanic8/org-agenda-api:latest"
}

variable "vm_size" {
  description = "VM size (shared-cpu-1x, shared-cpu-2x, etc.)"
  type        = string
  default     = "shared-cpu-1x"
}

variable "vm_memory" {
  description = "VM memory in MB"
  type        = number
  default     = 512
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
  description = "Custom elisp code to evaluate on startup (inline, not a file path)"
  type        = string
  default     = ""
}
