# The instance templates (docs/architecture/instance-templates.md): the VM each tier boots, which Batch builds from the template the controller names in
# RUNNER_TIERS. Runs against a mock google provider (no credentials), so it checks what the module asks for and not what Compute Engine
# does with it; the first job after an apply checks that (docs/architecture/instance-templates.md, "Checking a runner VM").
mock_provider "google" {}

override_resource {
  target = google_service_account.controller_runtime
  values = {
    email  = "controller-runtime@acme-runners.iam.gserviceaccount.com"
    member = "serviceAccount:controller-runtime@acme-runners.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.runner
  values = {
    email  = "runner@acme-runners.iam.gserviceaccount.com"
    member = "serviceAccount:runner@acme-runners.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.sweep
  values = {
    email  = "controller-sweep@acme-runners.iam.gserviceaccount.com"
    member = "serviceAccount:controller-sweep@acme-runners.iam.gserviceaccount.com"
  }
}

override_data {
  target = data.google_project.this
  values = {
    number = "123456789012"
  }
}

# The names are generated at apply (name_prefix), so a plan leaves them unknown, and the checks on RUNNER_TIERS need a value. An
# override applies to the resource and not to one instance of it, so every tier gets this name: the checks below cannot tell a tier
# paired with another tier's template, only that each path is built from a template name in the form the controller accepts.
override_resource {
  target = google_compute_instance_template.runner
  values = {
    name = "gh-tier-test-20261108120000000000000001"
  }
}

variables {
  project_id                 = "acme-runners"
  location                   = "europe-west3"
  batch_location             = "europe-west10"
  github_org                 = "acme-org"
  github_app_id              = 1
  github_app_installation_id = 2
  github_runner_group_id     = 3
  controller_image           = "europe-west3-docker.pkg.dev/acme-runners/cloudrun/controller:v0.1.0"
  boot_baked_image           = false
  runner_tiers = {
    gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    gcp-large  = { machine_type = "e2-standard-4", boot_disk_gb = 40, max_runners = 1 }
  }
}

run "every_tier_has_a_template_of_its_machine_and_disk" {
  command = plan

  assert {
    condition     = toset(keys(google_compute_instance_template.runner)) == toset(["gcp-medium", "gcp-large"])
    error_message = "there must be one instance template per tier, and no other"
  }

  assert {
    condition = {
      for label, t in google_compute_instance_template.runner : label => [t.machine_type, one([for d in t.disk : d.disk_size_gb]), one([for d in t.disk : d.disk_type])]
      } == {
      gcp-medium = ["e2-standard-2", 20, "pd-balanced"]
      gcp-large  = ["e2-standard-4", 40, "pd-balanced"]
    }
    error_message = "each template must carry its tier's machine type and boot disk size on a pd-balanced disk"
  }

  assert {
    condition     = alltrue([for t in google_compute_instance_template.runner : length(t.disk) == 1 && one(t.disk).boot == true && one(t.disk).auto_delete == true])
    error_message = "a template has one disk, the boot disk, and it is deleted with the VM"
  }
}

run "the_templates_use_the_standard_network_tier" {
  # The reason the templates exist: Batch cannot set a tier, and writes PREMIUM unless a template says otherwise.
  command = plan

  assert {
    condition = alltrue([
      for t in google_compute_instance_template.runner :
      length(t.network_interface) == 1 && length(one(t.network_interface).access_config) == 1 && one(one(t.network_interface).access_config).network_tier == "STANDARD"
    ])
    error_message = "every template must have exactly one interface with one external access config on the STANDARD tier"
  }

  assert {
    # Full paths: a bare subnetwork name would be looked up in the provider's region (europe-west3), not in batch_location.
    condition = alltrue([
      for t in google_compute_instance_template.runner :
      one(t.network_interface).network == "projects/acme-runners/global/networks/default" && one(t.network_interface).subnetwork == "projects/acme-runners/regions/europe-west10/subnetworks/default"
    ])
    error_message = "every template must be on the default network and the default subnetwork of batch_location"
  }
}

run "the_templates_are_spot_vms" {
  # Batch refuses a policy beside a template, so the provisioning model can only come from here.
  command = plan

  assert {
    condition = alltrue([
      for t in google_compute_instance_template.runner : length(t.scheduling) == 1 &&
      one(t.scheduling).provisioning_model == "SPOT" && one(t.scheduling).preemptible == true &&
      one(t.scheduling).automatic_restart == false && one(t.scheduling).on_host_maintenance == "TERMINATE" &&
      one(t.scheduling).instance_termination_action == "STOP"
    ])
    error_message = "every template must be a Spot VM that stops when preempted: Batch's managed instance groups refuse DELETE"
  }
}

run "the_templates_run_as_the_runner_account_with_the_firewall_tag" {
  command = plan

  assert {
    # Batch requires the job's service account to match the template's, and the job's is RUNNER_SERVICE_ACCOUNT.
    condition = alltrue([
      for t in google_compute_instance_template.runner : length(t.service_account) == 1 && one(t.service_account).email == google_service_account.runner.email
    ])
    error_message = "every template must run as the runner account"
  }

  assert {
    condition = alltrue([
      for t in google_compute_instance_template.runner : one(t.service_account).email == one([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.value if e.name == "RUNNER_SERVICE_ACCOUNT"])
    ])
    error_message = "the template's account must be the one the controller puts on the job"
  }

  assert {
    condition     = alltrue([for t in google_compute_instance_template.runner : t.tags == toset(["github-runner"])])
    error_message = "every template must carry the tag the deny-all-ingress rule targets"
  }

  assert {
    condition     = alltrue([for t in google_compute_instance_template.runner : t.tags == google_compute_firewall.deny_runner_ingress.target_tags || length(setintersection(t.tags, google_compute_firewall.deny_runner_ingress.target_tags)) == 1])
    error_message = "the tag on a template must be one the firewall rule targets"
  }
}

run "the_templates_boot_the_stock_image_unless_told_otherwise" {
  command = plan

  assert {
    condition     = alltrue([for t in google_compute_instance_template.runner : one(t.disk).source_image == "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"])
    error_message = "with boot_baked_image false the templates must boot the stock Ubuntu 24.04 family"
  }
}

run "the_templates_boot_the_image_they_are_given" {
  command = plan

  variables {
    boot_baked_image = true
  }

  assert {
    # The family and not an image, so that a rebuilt image needs no change to the template.
    condition     = alltrue([for t in google_compute_instance_template.runner : one(t.disk).source_image == "projects/acme-runners/global/images/family/gh-runner"])
    error_message = "boot_baked_image must be the source image of every template"
  }
}

run "a_template_is_named_from_a_prefix_so_that_it_can_be_replaced_before_it_is_deleted" {
  # A template is immutable, and a Batch job in flight names the old one. Only a name_prefix lets the new one exist beside it.
  command = plan

  assert {
    condition     = alltrue([for label, t in google_compute_instance_template.runner : t.name_prefix == "gh-tier-${label}-"])
    error_message = "every template must be named from the prefix gh-tier-<label>-"
  }

  assert {
    # The controller takes lowercase letters, digits and dashes in the name, and Terraform appends digits to the prefix.
    condition     = alltrue([for t in google_compute_instance_template.runner : can(regex("^[a-z][a-z0-9-]*$", t.name_prefix))])
    error_message = "a template name must be lowercase letters, digits and dashes, starting with a letter"
  }
}

run "the_controller_is_told_each_tiers_template_by_path" {
  command = plan

  assert {
    condition = jsondecode(one([
      for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.value if e.name == "RUNNER_TIERS"
      ])) == {
      for label, tier in var.runner_tiers : label => {
        machine_type      = tier.machine_type
        boot_disk_gb      = tier.boot_disk_gb
        max_runners       = tier.max_runners
        instance_template = "projects/acme-runners/global/instanceTemplates/${google_compute_instance_template.runner[label].name}"
      }
    }
    error_message = "RUNNER_TIERS must name each tier's own template as projects/<project>/global/instanceTemplates/<name>"
  }

  assert {
    # The path form and not the URL, which the controller refuses (github-actions-runner-controller, crates/controller/src/tier.rs, InstanceTemplate).
    condition = alltrue([
      for label, tier in jsondecode(one([
        for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.value if e.name == "RUNNER_TIERS"
      ])) : can(regex("^projects/acme-runners/global/instanceTemplates/[a-z0-9-]+$", tier.instance_template))
    ])
    error_message = "every instance_template must be a projects/<project>/global/instanceTemplates/<name> path"
  }
}

run "the_longest_label_leaves_the_prefix_within_the_provider_limit" {
  # Terraform appends 26 characters; a prefix over 37 makes the provider shorten them and risk a collision (variables.tf).
  command = plan

  variables {
    runner_tiers = {
      aaaaaaaaaaaaaaaaaaaaaaaaaaaa = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  assert {
    condition     = alltrue([for t in google_compute_instance_template.runner : length(t.name_prefix) == 37])
    error_message = "a 28 character label must give a 37 character prefix, the most the provider keeps the full suffix for"
  }
}
