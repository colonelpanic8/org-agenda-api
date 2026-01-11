terraform {
  required_version = ">= 1.0"

  required_providers {
    fly = {
      source  = "fly-apps/fly"
      version = "~> 0.1"
    }
  }
}

provider "fly" {
  # Set FLY_API_TOKEN environment variable or use:
  # fly_api_token = var.fly_api_token
}
