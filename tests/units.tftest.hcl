# What sets two deployment units of one project apart (unit.tf, docs/architecture/deployment-units.md): every name the module makes
# carries the unit's prefix, the controller labels its Batch jobs with the unit, and the unit boots its own image family. Runs against
# a mock google provider (no credentials).
mock_provider "google" {}

override_data {
  target = data.google_project.this
  values = {
    number = "834662790614"
  }
}

override_data {
  target = data.google_secret_manager_secret_version.newest
  values = {
    version = "1"
  }
}

variables {
  name                       = "demo"
  project_id                 = "github-runners-prd"
  location                   = "europe-west3"
  batch_location             = "europe-west10"
  github_org                 = "voron-simulations"
  github_app_id              = 1234567
  github_app_installation_id = 89012345
  github_runner_group_id     = 3
  controller_image           = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0"
  runner_tiers = {
    gcp-small = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 2 }
  }
}

run "every_name_carries_the_unit_prefix" {
  command = plan

  assert {
    condition = jsonencode(sort([
      google_service_account.controller_runtime.account_id,
      google_service_account.runner.account_id,
      google_service_account.sweep.account_id,
      google_cloud_run_v2_service.controller[0].name,
      google_cloud_scheduler_job.sweep[0].name,
      google_compute_firewall.deny_runner_ingress.name,
      ])) == jsonencode(sort([
      "demo-controller-runtime",
      "demo-runner",
      "demo-controller-sweep",
      "demo-controller",
      "demo-sweep-idle-runners",
      "demo-gh-runner-deny-ingress",
    ]))
    error_message = "a named unit must prefix every name with `<name>-`"
  }

  assert {
    condition     = jsonencode(sort([for s in google_secret_manager_secret.controller : s.secret_id])) == jsonencode(["demo-github-app-private-key", "demo-github-webhook-secret"])
    error_message = "a named unit's secrets must carry its prefix"
  }

  assert {
    condition     = google_compute_instance_template.runner["gcp-small"].name_prefix == "gh-tier-demo-gcp-small-"
    error_message = "a named unit's templates must carry its prefix after `gh-tier-`"
  }

  assert {
    # The controller's URL is made from the service name, and the sweep calls it there.
    condition     = google_cloud_scheduler_job.sweep[0].http_target[0].uri == "https://demo-controller-834662790614.europe-west3.run.app/sweep"
    error_message = "the sweep must call the unit's own controller"
  }
}

run "the_controller_serves_its_unit" {
  command = plan

  assert {
    condition     = [for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.value if e.name == "DEPLOYMENT_UNIT"] == ["demo"]
    error_message = "a named unit's controller must get DEPLOYMENT_UNIT, or it would take other units' Batch jobs for its own"
  }
}

run "the_legacy_unit_has_no_deployment_unit" {
  command = plan

  variables {
    legacy_names = true
  }

  assert {
    condition     = !contains([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name], "DEPLOYMENT_UNIT")
    error_message = "the legacy unit's jobs carry no unit label, so its controller must serve no unit"
  }

  assert {
    condition     = google_cloud_run_v2_service.controller[0].name == "controller"
    error_message = "the legacy unit keeps its unprefixed names"
  }
}

run "a_unit_boots_its_own_family" {
  command = plan

  variables {
    boot_baked_image = true
  }

  assert {
    condition     = one(google_compute_instance_template.runner["gcp-small"].disk).source_image == "projects/github-runners-prd/global/images/family/gh-runner-demo"
    error_message = "a named unit must boot its own family, gh-runner-<name>"
  }
}

run "the_legacy_unit_boots_the_old_family" {
  command = plan

  variables {
    legacy_names     = true
    boot_baked_image = true
  }

  assert {
    condition     = one(google_compute_instance_template.runner["gcp-small"].disk).source_image == "projects/github-runners-prd/global/images/family/gh-runner"
    error_message = "the legacy unit must keep booting gh-runner"
  }
}

run "the_unit_prefix_counts_against_the_template_name" {
  # 23 characters is within the label's own limit of 28, and with `gh-tier-demo-` and the closing dash it makes a prefix of 37.
  command = plan

  variables {
    runner_tiers = {
      aaaaaaaaaaaaaaaaaaaaaaa = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 1 }
    }
  }
}

run "a_label_too_long_for_the_unit_prefix_fails" {
  command = plan

  variables {
    runner_tiers = {
      aaaaaaaaaaaaaaaaaaaaaaaa = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  expect_failures = [google_compute_instance_template.runner]
}

run "a_baked_image_needs_its_disk" {
  command = plan

  variables {
    boot_baked_image = true
    runner_tiers = {
      gcp-small = { machine_type = "e2-medium", boot_disk_gb = 10, max_runners = 1 }
    }
  }

  expect_failures = [google_compute_instance_template.runner]
}

run "rejects_names_that_do_not_fit_a_service_account_id" {
  command = plan

  variables {
    name = "abcdefghijkl"
  }

  expect_failures = [var.name]
}

run "rejects_a_name_that_starts_with_a_digit" {
  command = plan

  variables {
    name = "1demo"
  }

  expect_failures = [var.name]
}

run "a_unit_waiting_for_its_secrets_plans_without_reading_them" {
  # The newest-version read is overridden above, so this checks that nothing reads it at all: an empty for_each.
  command = plan

  variables {
    controller_enabled = false
  }

  assert {
    condition     = length(google_cloud_run_v2_service.controller) == 0 && length(google_cloud_scheduler_job.sweep) == 0
    error_message = "with the controller off there must be no service and no sweep"
  }

  assert {
    condition     = length(data.google_secret_manager_secret_version.newest) == 0
    error_message = "with the controller off nothing may read the secrets' versions, which do not exist yet"
  }

  assert {
    condition     = length(google_secret_manager_secret.controller) == 2
    error_message = "the secrets must exist so that a person can add their versions"
  }

  assert {
    condition     = output.webhook_url == "https://demo-controller-834662790614.europe-west3.run.app/webhook"
    error_message = "the webhook URL must be known before the controller is on, for the GitHub App"
  }
}
