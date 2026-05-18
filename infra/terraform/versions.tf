terraform {
  # Pinned so a teammate on a different Terraform minor can't produce a
  # divergent plan. Bump deliberately, in a separate commit, so version
  # changes show up in code review.
  required_version = ">= 1.6.0"

  required_providers {
    lxd = {
      source  = "terraform-lxd/lxd"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
