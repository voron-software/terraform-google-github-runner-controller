# One instance template per tier: the VM a runner of that tier boots (docs/architecture/instance-templates.md). The controller hands the template's path to Batch in
# the job's allocation policy (RUNNER_TIERS, cloudrun.tf), and Batch creates the VM from it.
#
# Why Batch is given a template and not described the VM inline: the runner VMs' egress was billed at the Premium network tier.
# the project default was STANDARD, but Batch writes `networkTier: PREMIUM` into every instance and instance template it
# creates, and a tier on the resource beats the project default. Batch's NetworkInterface has no tier field, so a template whose
# access config says STANDARD is the only lever. Cloud NAT was the alternative and costs more than the whole runner bill.
#
# What follows from that choice: in a Batch allocation policy an inline `policy` and an `instanceTemplate` are exclusive, so the
# machine, the Spot provisioning model, the disk, the image and the network all move here from the controller's job. The job keeps
# only what Batch takes from it beside a template: the service account (which must be the one set below), the tags, the labels and
# the location. Whether Batch honours the template's Spot scheduling and its tier is not in its documentation, so the first job after
# an apply has to show both (gcp-github-runners docs/operations/deploys.md, "Checking a runner VM's template settings").
locals {
  # The fallback when `boot_baked_image` is false (docs/architecture/runner-image.md): Canonical's current Ubuntu 24.04, on which runner.sh installs everything at
  # boot. The controller has the same literal as its default for RUNNER_BOOT_IMAGE, which goes with that variable (target state in
  # docs/architecture/instance-templates.md).
  stock_boot_image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"

  # The family, not an image, so the weekly rebuild needs no apply.
  runner_image = var.boot_baked_image ? "projects/${var.project_id}/global/images/family/${local.image_family}" : local.stock_boot_image

  # The disk the unit's image is built on (image/action.yml, `build-disk-gb`), and so the smallest boot disk a VM booting it can
  # have. A test in checks/ compares the two.
  image_disk_gb = 20
}

resource "google_compute_instance_template" "runner" {
  for_each = var.runner_tiers

  project      = var.project_id
  machine_type = each.value.machine_type
  description  = "Runner VM of the ${each.key} tier (docs/architecture/instance-templates.md). Replaced, not edited, when the tier changes."

  # A template cannot be changed once it exists, so a change to a tier replaces it. The prefix lets Terraform give the replacement
  # a new name (it appends a unique suffix), which is what makes create-before-destroy possible: the new template exists, the
  # controller's RUNNER_TIERS names it, and only then is the old one deleted. A job that Batch accepted but has not yet provisioned
  # still names the old template, so it fails if the old one goes first (docs/architecture/instance-templates.md, "Immutability"). The prefix is `gh-tier-` like
  # the `gh-tier` label on the VMs, short because Compute Engine caps a name at 63 characters, the provider's suffix takes 26 and a
  # longer prefix makes it shorten the suffix and risk a collision. That leaves 37 for the prefix, which is why `runner_tiers`
  # labels stop at 28 characters (variables.tf).
  name_prefix = "gh-tier-${local.name_prefix}${each.key}-"

  # The tag the deny-all-ingress rule targets (firewall.tf). The job sets it too, but Batch does not say that the job's tags still
  # apply to a VM made from a template, and a VM without the tag would have the default network's open SSH and RDP rules. So the
  # template carries it, and the first job has to show it on the VM.
  tags = ["github-runner"]

  # Spot lives in the template because Batch refuses a `policy` beside a template, and `provisioningModel` is a field of the
  # policy. The other two are what Compute Engine requires of a Spot VM. The termination action is STOP, the Spot default and what
  # the controller's inline policy got, because Batch runs the template in a managed instance group, and a MIG refuses Spot VMs set
  # to DELETE (every job failed with CODE_GCE_UNSUPPORTED_OPERATION on 2026-11-09). A stopped VM does not linger: its task fails,
  # and Batch deletes the group when the job ends. It is spelled out so that the value the API reports matches the config.
  scheduling {
    provisioning_model          = "SPOT"
    preemptible                 = true
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = "STOP"
  }

  disk {
    boot        = true
    auto_delete = true
    # The family, not an image: Compute Engine resolves a family to its newest image when it creates a VM, so the weekly image
    # rebuild (docs/architecture/runner-image.md) needs no change here. With `boot_baked_image` false this is the stock Ubuntu family. Both the template and
    # RUNNER_BOOT_IMAGE (cloudrun.tf) read the variable, so they cannot name different images.
    source_image = local.runner_image
    # Balanced, not SSD: SSD was only about 7% faster on IO-bound steps, which its price does not justify (docs/architecture/instance-templates.md, "Why pd-balanced and not pd-ssd").
    disk_type    = "pd-balanced"
    disk_size_gb = each.value.boot_disk_gb
  }

  network_interface {
    # Spelled out as the controller's inline job did: the placement does not depend on a default, and the firewall rule is written
    # for this network. The subnetwork has to be a full path, because a bare name is looked up in the provider's region, which is
    # not `batch_location`, where the VMs are. The template's own `region` is left unset on purpose: a template is global, the
    # provider reads `region` back from this subnetwork and never from its own configuration, and as a forces-new attribute a value
    # set here that differed from the recorded one would replace every template.
    network    = "projects/${var.project_id}/global/networks/default"
    subnetwork = "projects/${var.project_id}/regions/${var.batch_location}/subnetworks/default"

    # An external IP, because the VM has no other way to reach GitHub, Docker Hub or the runner download (no Cloud NAT, docs/architecture/instance-templates.md,
    # "Why not Cloud NAT"). The tier is the point of this file.
    access_config {
      network_tier = "STANDARD"
    }
  }

  # Batch requires the job's service account to be the one named here, and sets the job's from RUNNER_SERVICE_ACCOUNT, which is the
  # same account. The scope is the one the controller's job sent: IAM, not the scope, limits what the account can do.
  service_account {
    email  = google_service_account.runner.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true

    # The unit's prefix is in the name too, so the 28 characters the label may have (variables.tf) shrink by its length.
    precondition {
      condition     = length("gh-tier-${local.name_prefix}${each.key}-") <= 37
      error_message = "The instance template prefix of tier ${each.key} is longer than 37 characters; shorten the tier label or the unit name."
    }

    # A VM cannot boot from a disk smaller than its image.
    precondition {
      condition     = !var.boot_baked_image || each.value.boot_disk_gb >= local.image_disk_gb
      error_message = "Tier ${each.key} has a ${each.value.boot_disk_gb} GB boot disk, smaller than the ${local.image_disk_gb} GB the unit's image is built on."
    }
  }
}
