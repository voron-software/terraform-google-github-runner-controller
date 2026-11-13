# What makes one deployment unit apart from another in the same project (docs/architecture/deployment-units.md): its name, which
# prefixes the name of every resource the module creates and labels its controller's Batch jobs, and the image family it builds and
# boots.

variable "name" {
  type        = string
  description = "Name of the deployment unit, unique in its project. It prefixes every resource the module creates and is the controller's DEPLOYMENT_UNIT. A lowercase letter, then up to 10 lowercase letters, digits and dashes, ending in a letter or digit."

  validation {
    # 11 characters at most because a service account id is at most 30, and the longest the module makes is
    # `<name>-controller-runtime` (12 + 18).
    condition     = can(regex("^[a-z]([a-z0-9-]{0,9}[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase letter, then up to 10 lowercase letters, digits and dashes, ending in a letter or digit."
  }
}

# Only for the installation that existed before units did: its resources were created without a prefix, its Batch jobs carry no unit
# label and its image family is `gh-runner`, and renaming any of them would replace its secrets, its service accounts and the Batch
# jobs that are running. At most one unit of a project may set it, which the caller's root checks, because a module instance cannot
# see the others.
variable "legacy_names" {
  type        = bool
  description = "Name the resources as before deployment units existed: no prefix, no DEPLOYMENT_UNIT and the image family `gh-runner`. Only for the one installation that predates units; at most one unit of a project may set it."
  default     = false
  nullable    = false
}

# A new unit cannot start its controller until a person has added the two secret versions, and the module reads the newest version
# of each secret at plan time, so a unit without them fails the whole plan of the root that calls it, other units included. Off, the
# unit creates its accounts, secrets, firewall rule and templates and no service, no sweep and no read of the secrets; turning it on
# after the versions exist creates the rest (gcp-github-runners docs/operations/adding-a-unit.md).
variable "controller_enabled" {
  type        = bool
  description = "Run the unit's controller and its sweep. False until the unit's two secrets have a version each; the webhook URL output is known either way, for the GitHub App."
  default     = true
  nullable    = false
}

locals {
  # Every resource name the module makes starts with this, so two units of one project never share a name.
  name_prefix = var.legacy_names ? "" : "${var.name}-"

  # The family the unit's image build (image/action.yml) adds to and the runner VMs boot. It starts with `gh-runner-` or is
  # `gh-runner`, because cloud-iac's `vmimages` capability admits images by that name only; image/action.yml derives it by the same
  # rule, and a test in checks/ compares them.
  image_family = var.legacy_names ? "gh-runner" : "gh-runner-${var.name}"
}
