variable "project_id" {
  type        = string
  description = "Project the controller, the runner VMs and everything else this module creates live in. Every resource names it explicitly, so the provider needs no default project."
}

# Every regional resource of the module names its region, so the provider's own `region` is not read.
variable "location" {
  type        = string
  description = "Region of the Cloud Run controller and the Cloud Scheduler job that calls it."
}

# Separate from `location` on purpose: the controller stays in `location` while the VMs may run where Spot VMs are cheaper or the
# quota is larger, as long as Cloud Batch supports the region. Moving the VMs is a change of this value: jobs already running
# finish where they started. The external address quota that caps concurrent jobs is the one of this region, not of `location`
# (docs/reference/tiers.md, "Quota").
variable "batch_location" {
  type        = string
  description = "Region Cloud Batch creates the runner VMs in, which Batch must support. The controller's BATCH_LOCATION."
}

# Required, with no default, and refused unless it is pinned: the module has no pipeline to roll an image out, so what the service runs
# is exactly this value, and a reference that moves (`latest`, a bare repository, a branch's tag) would let the same apply run
# different code on different days. Two forms are pinned. A release tag `v<X.Y.Z>` is what gcp-runner-controller docs/operations/releases.md cuts, and the
# publisher's repository keeps tags immutable. A digest names the bits whatever the registry does, so it is also the way to run an
# image that has no release, such as a build of one commit or a copy in a registry of the caller's own. The commit-sha tags that the
# publisher's build pushes are refused on purpose: nothing in this module can tell them from any other tag, they are not releases,
# and a digest says the same thing without trusting the registry. Both forms may be given together (`:v1.2.3@sha256:...`), and
# Cloud Run then pulls the digest. A release has no pre-release suffix (the Build workflow refuses one), so none is accepted.
# The name must start with a registry host, as Docker reads one: a first path component that has a `.` or a `:` or is `localhost`.
# Without one the reference names a Docker Hub namespace by default (`team/controller`), and a pin should say where it is pulled from.
variable "controller_image" {
  type        = string
  description = "Full reference of the controller image the Cloud Run service runs, pinned: `<registry>/<path>:v<X.Y.Z>`, a release tag (gcp-runner-controller docs/operations/releases.md), or `<registry>/<path>@sha256:<64 hex digits>`, or both. Not `latest`, not a bare repository and not a commit's tag. Changing it deploys the new image at the next apply."

  validation {
    # The second test is the host rule, which the first cannot say without a lookahead: the text up to the first `/` has a `.` or a
    # `:`, or is `localhost`.
    condition = (
      can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9]+([._-]+[a-z0-9]+)*)+(:v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(@sha256:[a-f0-9]{64})?|@sha256:[a-f0-9]{64})$", var.controller_image))
      && can(regex("^([^/]*[.:][^/]*|localhost)/", var.controller_image))
    )
    error_message = "controller_image must be a registry host and path pinned to a release or a digest: <registry host>/<path>:v<X.Y.Z> or <registry host>/<path>@sha256:<64 hex digits>. A tag other than a release's, `latest`, a bare repository and a name with no registry host (`team/controller`) are refused."
  }
}

# The three GitHub ids below have no default on purpose: they exist only after the GitHub App and the runner group are created
# (gcp-github-runners docs/operations/adding-a-unit.md), and a forgotten value should fail the plan instead of deploying a controller that points nowhere.
# They are numbers in GitHub's API and strings in the controller's environment, hence tostring() in cloudrun.tf.
variable "github_app_id" {
  type        = number
  description = "Numeric id of the GitHub App (the App ID on its settings page)."

  validation {
    condition     = var.github_app_id >= 0 && var.github_app_id == floor(var.github_app_id)
    error_message = "github_app_id must be a non-negative whole number."
  }
}

variable "github_app_installation_id" {
  type        = number
  description = "Numeric id of the App's installation on the org (the last path segment of the installation's settings URL). The controller ignores webhooks from any other installation."

  validation {
    condition     = var.github_app_installation_id >= 0 && var.github_app_installation_id == floor(var.github_app_installation_id)
    error_message = "github_app_installation_id must be a non-negative whole number."
  }
}

variable "github_runner_group_id" {
  type        = number
  description = "Id of the org runner group that holds the runners, from `gh api orgs/<org>/actions/runner-groups`. The group's repository access list is what keeps public and unrelated repositories off these machines."

  validation {
    condition     = var.github_runner_group_id >= 0 && var.github_runner_group_id == floor(var.github_runner_group_id)
    error_message = "github_runner_group_id must be a non-negative whole number."
  }
}

variable "github_org" {
  type        = string
  description = "GitHub organisation the runners serve. The controller's GITHUB_ORG."
}

# The tiers of runner a job can ask for (docs/reference/tiers.md): the key is the label a job names alone in `runs-on` (gcp-runner-controller docs/architecture/scale-sets.md), and the value
# is the VM that serves it. The controller reads the whole map as the JSON object RUNNER_TIERS (cloudrun.tf). Every rule below
# is one the controller enforces at start-up, in gcp-runner-controller crates/controller/src/tier.rs, repeated here so
# that a value that would stop the controller fails the plan instead of the deploy. Change both repositories together.
#
# The labels are disjoint on purpose: a runner carries `self-hosted` and its own tier's label and no other, because GitHub gives a
# queued job to any idle runner that holds all of the job's labels. A shared label plus a size label would let a plain job take a
# large runner and leave the large job's own VM idle.
variable "runner_tiers" {
  type = map(object({
    machine_type = string
    boot_disk_gb = number
    max_runners  = number
  }))
  description = "Runner tiers, keyed by the label a job asks for in `runs-on`. Each has a Compute Engine `machine_type`, a `boot_disk_gb`, which may not be smaller than the runner image's disk (20 GB), and `max_runners`, the most runners of the tier at once; each gets an instance template of that machine and disk, and a runner scale set named after the label. The controller's RUNNER_TIERS."
  # No default, as for the GitHub ids: a controller with no tier serves nothing, and a forgotten value should fail the plan.

  validation {
    condition     = length(var.runner_tiers) >= 1
    error_message = "runner_tiers needs at least one tier."
  }

  validation {
    # Lowercase only, because GitHub compares labels without regard to case and a second spelling could only collide. The label is
    # part of each runner's name, `runner-<label>-<16 hex digits>`, which names its Batch job; Batch caps a job name at 63
    # characters, which leaves 39 for the label, and a name with a dash at either end of the label is not one the controller reads
    # as its own.
    condition     = alltrue([for label in keys(var.runner_tiers) : can(regex("^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?$", label))])
    error_message = "Every tier label in runner_tiers must be 1 to 39 lowercase letters, digits and dashes, and start and end with a letter or digit."
  }

  validation {
    # The label is in the name of the tier's instance template, `gh-tier-<label>-` plus the 26 characters Terraform appends, and
    # Compute Engine caps a name at 63. A prefix over 37 makes the provider shorten the suffix and risk a collision, so the prefix
    # (instance-templates.tf, `name_prefix`) is held to 37: 8 for `gh-tier-`, 1 for the closing dash, 28 for the label. The
    # controller itself accepts up to 63.
    condition     = alltrue([for label in keys(var.runner_tiers) : length("gh-tier-${label}-") <= 37])
    error_message = "Every tier label in runner_tiers must be at most 28 characters, because the tier's instance template is named after it and Compute Engine caps names at 63."
  }

  validation {
    # `self-hosted` is on every self-hosted runner already; as the label of one tier it would claim every self-hosted job.
    condition     = !contains(keys(var.runner_tiers), "self-hosted")
    error_message = "`self-hosted` cannot be a tier label."
  }

  validation {
    condition     = alltrue([for tier in values(var.runner_tiers) : can(regex("^[a-z0-9-]+$", tier.machine_type))])
    error_message = "Every machine_type in runner_tiers must be lowercase letters, digits and dashes, such as e2-standard-2."
  }

  validation {
    # 10 GB is the stock Ubuntu image's disk, the least Compute Engine will create from it. With the baked image the floor is the
    # image's disk, 20 GB (docs/reference/tiers.md, "Disk size"); 2000 GB keeps a typo from being billed by the minute.
    condition     = alltrue([for tier in values(var.runner_tiers) : tier.boot_disk_gb >= 10 && tier.boot_disk_gb <= 2000 && tier.boot_disk_gb == floor(tier.boot_disk_gb)])
    error_message = "Every boot_disk_gb in runner_tiers must be a whole number from 10 to 2000."
  }

  validation {
    # The controller never runs more of a tier at once, and sends it to GitHub as the scale set's capacity. 100 is far above what the
    # quotas allow (docs/reference/tiers.md, "Quota") and keeps a typo from becoming a bill.
    condition     = alltrue([for tier in values(var.runner_tiers) : tier.max_runners >= 1 && tier.max_runners <= 100 && tier.max_runners == floor(tier.max_runners)])
    error_message = "Every max_runners in runner_tiers must be a whole number from 1 to 100."
  }
}

# False boots the stock Ubuntu 24.04 family, on which runner.sh installs everything at boot. That is also the fallback: set this back
# to false to stop booting the baked image (docs/architecture/runner-image.md). The unit's family does not exist until its image has
# been built once (image/action.yml), so setting this earlier makes every job fail to get a VM. The instance templates
# (instance-templates.tf) name the image, and RUNNER_BOOT_IMAGE carries it too until the controller stops reading that
# (docs/architecture/instance-templates.md, "The controller's side").
variable "boot_baked_image" {
  type        = bool
  description = "Boot the runner VMs from the unit's own image family (`gh-runner-<name>` in the unit's project, built by image/action.yml) instead of the stock Ubuntu 24.04 family. Leave false until the first image build has succeeded."
  default     = false
  nullable    = false
}

# The three settings below (`runner_max_run_seconds`, `sweep_grace_seconds`, `scaleset_poll_timeout_ms`) are not nullable, so that
# a caller which wraps this module and has no opinion can pass its own unset variable, which is null, and get the default here
# instead of a controller environment variable with no value.
variable "runner_max_run_seconds" {
  type        = number
  description = "Longest a runner task may run before Batch kills it and deletes the VM. The backstop for a lost `completed` webhook, and so also the longest job these runners can run. The controller's RUNNER_MAX_RUN_SECONDS."
  default     = 21600
  nullable    = false

  validation {
    condition     = var.runner_max_run_seconds >= 1 && var.runner_max_run_seconds == floor(var.runner_max_run_seconds)
    error_message = "runner_max_run_seconds must be a positive whole number of seconds."
  }
}

# The bounds are the controller's own (gcp-runner-controller, crates/controller/src/reconcile.rs), repeated so that a value
# the controller would refuse at start-up fails the plan instead.
variable "sweep_grace_seconds" {
  type        = number
  description = "How long a runner's Batch job must have been RUNNING with no runner registration before the reconcile deletes it as an orphan. The controller's SWEEP_GRACE_SECONDS."
  default     = 90
  nullable    = false

  validation {
    condition     = var.sweep_grace_seconds >= 1 && var.sweep_grace_seconds <= 3600 && var.sweep_grace_seconds == floor(var.sweep_grace_seconds)
    error_message = "sweep_grace_seconds must be a whole number of seconds from 1 to 3600."
  }
}

# The bounds are the controller's own (gcp-runner-controller, crates/controller/src/poll.rs), repeated so that a value the controller refuses fails the plan.
variable "scaleset_poll_timeout_ms" {
  type        = number
  description = "How long one poll of a tier's scale set message queue waits before it is taken to mean there are no messages (gcp-runner-controller docs/architecture/scale-sets.md, Polling). GitHub holds a poll of an empty queue for about 50 s, so this is what bounds each reconcile's read. The controller's SCALESET_POLL_TIMEOUT_MS."
  default     = 1000
  nullable    = false

  validation {
    condition     = var.scaleset_poll_timeout_ms >= 100 && var.scaleset_poll_timeout_ms <= 60000 && var.scaleset_poll_timeout_ms == floor(var.scaleset_poll_timeout_ms)
    error_message = "scaleset_poll_timeout_ms must be a whole number of milliseconds from 100 to 60000."
  }
}
