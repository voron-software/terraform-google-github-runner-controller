# What a deployment unit is in its project (docs/architecture/deployment-units.md): fixed names, because a project holds one unit,
# the family its own image build makes, and a controller that can wait for its secrets. Runs against a mock google provider (no
# credentials).
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

run "a_unit_has_the_fixed_names_its_image_build_and_docs_use" {
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
      "controller-runtime",
      "runner",
      "controller-sweep",
      "controller",
      "sweep-idle-runners",
      "gh-runner-deny-ingress",
    ]))
    error_message = "the unit's resources must keep their fixed names: renaming one replaces it, the secrets and accounts included"
  }

  assert {
    condition     = jsonencode(sort([for s in google_secret_manager_secret.controller : s.secret_id])) == jsonencode(["github-app-private-key", "github-webhook-secret"])
    error_message = "the secrets must keep their names, which the runbooks and the secret operator use"
  }

  assert {
    # The controller's URL is made from the service name, and the sweep calls it there.
    condition     = google_cloud_scheduler_job.sweep[0].http_target[0].uri == "https://controller-834662790614.europe-west3.run.app/sweep"
    error_message = "the sweep must call the unit's own controller"
  }

  assert {
    condition     = !contains([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name], "DEPLOYMENT_UNIT")
    error_message = "the controller owns every runner job of its project, so it gets no unit to filter by"
  }
}

run "a_unit_boots_the_family_its_image_build_makes" {
  command = plan

  variables {
    boot_baked_image = true
  }

  assert {
    condition     = one(google_compute_instance_template.runner["gcp-small"].disk).source_image == "projects/github-runners-prd/global/images/family/gh-runner"
    error_message = "the unit must boot the family gh-runner in its own project, which image/action.yml builds"
  }

  assert {
    condition     = output.image_family == "gh-runner"
    error_message = "the image_family output must name the family the templates boot"
  }
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
    condition     = output.webhook_url == "https://controller-834662790614.europe-west3.run.app/webhook"
    error_message = "the webhook URL must be known before the controller is on, for the GitHub App"
  }
}
