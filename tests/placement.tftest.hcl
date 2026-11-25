# Where every resource lives. The module is called from roots with their own provider configuration, so no resource may take its
# project or region from the provider: each names them. Runs against a mock google provider, which fills an attribute left to the
# provider with a random string, so a resource that relies on a default fails the comparison below. It checks only the resources it
# names, so checks/tests/module.rs fails on a resource of the module that is not named here.
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

variables {
  project_id                 = "acme-runners"
  location                   = "europe-west3"
  batch_location             = "europe-west10"
  github_org                 = "acme-org"
  github_app_id              = 1
  github_app_installation_id = 2
  github_runner_group_id     = 3
  controller_image           = "europe-west3-docker.pkg.dev/acme-runners/cloudrun/controller:v0.1.0"
  runner_tiers = {
    gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    gcp-large  = { machine_type = "e2-standard-4", boot_disk_gb = 40, max_runners = 1 }
  }
}

run "every_resource_names_its_project" {
  command = plan

  assert {
    condition = alltrue(concat(
      [
        google_service_account.controller_runtime.project == var.project_id,
        google_service_account.runner.project == var.project_id,
        google_service_account.sweep.project == var.project_id,
        google_cloud_run_v2_service.controller[0].project == var.project_id,
        google_cloud_scheduler_job.sweep[0].project == var.project_id,
        google_compute_firewall.deny_runner_ingress.project == var.project_id,
        data.google_project.this.project_id == var.project_id,
      ],
      [for k, d in data.google_secret_manager_secret_version.newest : d.project == var.project_id],
      [for k, r in google_project_iam_member.controller_runtime : r.project == var.project_id],
      [for k, r in google_project_iam_member.runner : r.project == var.project_id],
      [for k, r in google_secret_manager_secret.controller : r.project == var.project_id],
      [for k, r in google_secret_manager_secret_iam_member.controller_accessor : r.project == var.project_id],
      [for k, r in google_compute_instance_template.runner : r.project == var.project_id],
      [for k, r in google_cloud_tasks_queue.waiting : r.project == var.project_id],
      [google_cloud_tasks_queue.wakeups.project == var.project_id],
    ))
    error_message = "every resource must set its project to project_id and not leave it to the provider"
  }
}

run "every_regional_resource_names_its_region" {
  command = plan

  assert {
    # The controller and its scheduler job are in `location`: the sweep's audience is made from the service's region.
    condition     = google_cloud_run_v2_service.controller[0].location == var.location && google_cloud_scheduler_job.sweep[0].region == var.location
    error_message = "the controller and the scheduler job must be in location"
  }

  # The instance templates are exempt, and have no assertion: a template is a global resource, and the provider reads its `region`
  # back from the subnetwork in its network interface, never from the provider's configuration. The subnetwork is a full path in
  # batch_location (tests/templates.tftest.hcl), so the region does not depend on the caller. Setting `region` as well would be a
  # forces-new value to keep equal to what the provider records (instance-templates.tf).
}
