# No provider block and no backend: the caller configures both, and a module that declared them could not be called twice or from
# a root that already has them.
terraform {
  # The oldest release the module is claimed to work with; nothing tests an older one.
  required_version = ">= 1.11"

  required_providers {
    google = {
      source = "hashicorp/google"
      # The major this module is tested with, so that a breaking provider release is a change someone makes on purpose.
      version = "~> 8.0"
    }
  }
}
