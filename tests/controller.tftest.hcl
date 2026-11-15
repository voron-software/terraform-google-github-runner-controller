# The controller side of github-actions-runner-controller docs/architecture/overview.md: the Cloud Run service, its environment (the contract with github-actions-runner-controller), its identity and
# its secrets. Runs against a mock google provider (no credentials).
mock_provider "google" {}

override_resource {
  target = google_service_account.controller_runtime
  values = {
    email  = "controller-runtime@github-runners-prd.iam.gserviceaccount.com"
    member = "serviceAccount:controller-runtime@github-runners-prd.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.runner
  values = {
    email  = "runner@github-runners-prd.iam.gserviceaccount.com"
    member = "serviceAccount:runner@github-runners-prd.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.sweep
  values = {
    email  = "controller-sweep@github-runners-prd.iam.gserviceaccount.com"
    member = "serviceAccount:controller-sweep@github-runners-prd.iam.gserviceaccount.com"
  }
}

# The templates' names are generated at apply (name_prefix), so a plan leaves them unknown, and RUNNER_TIERS is made from them.
# tests/templates.tftest.hcl says what the override cannot show.
override_resource {
  target = google_compute_instance_template.runner
  values = {
    name = "gh-tier-test-20261108120000000000000001"
  }
}

# The project number of github-runners-prd, which the controller's deterministic URL is made from.
override_data {
  target = data.google_project.this
  values = {
    number = "834662790614"
  }
}

variables {
  project_id                 = "github-runners-prd"
  location                   = "europe-west3"
  batch_location             = "europe-west10"
  github_org                 = "voron-software"
  github_app_id              = 1234567
  github_app_installation_id = 89012345
  github_runner_group_id     = 3
  controller_image           = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0"
  # The environment checks below start from the unset state; the run that needs an image sets one itself.
  boot_baked_image = false
  runner_tiers = {
    gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    gcp-large  = { machine_type = "e2-standard-4", boot_disk_gb = 40, max_runners = 1 }
  }
}

run "controller_environment_is_the_contract" {
  command = plan

  assert {
    condition = {
      for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name => e.value if length(e.value_source) == 0
      } == {
      GITHUB_APP_ID              = "1234567"
      GITHUB_APP_INSTALLATION_ID = "89012345"
      GITHUB_ORG                 = "voron-software"
      GITHUB_RUNNER_GROUP_ID     = "3"
      GCP_PROJECT                = "github-runners-prd"
      BATCH_LOCATION             = "europe-west10"
      RUNNER_SERVICE_ACCOUNT     = "runner@github-runners-prd.iam.gserviceaccount.com"
      RUNNER_TIERS               = "{\"gcp-large\":{\"boot_disk_gb\":40,\"instance_template\":\"projects/github-runners-prd/global/instanceTemplates/gh-tier-test-20261108120000000000000001\",\"machine_type\":\"e2-standard-4\",\"max_runners\":1},\"gcp-medium\":{\"boot_disk_gb\":20,\"instance_template\":\"projects/github-runners-prd/global/instanceTemplates/gh-tier-test-20261108120000000000000001\",\"machine_type\":\"e2-standard-2\",\"max_runners\":1}}"
      RUNNER_MAX_RUN_SECONDS     = "21600"
      SWEEP_AUDIENCE             = "https://controller-834662790614.europe-west3.run.app"
      SWEEP_CALLER               = "controller-sweep@github-runners-prd.iam.gserviceaccount.com"
      SWEEP_GRACE_SECONDS        = "90"
      SCALESET_POLL_TIMEOUT_MS   = "1000"
    }
    error_message = "the plain environment must be exactly the variables github-actions-runner-controller docs/reference/configuration.md lists"
  }

  assert {
    # RUNNER_TIERS replaces the single label and machine type; a leftover would be a setting that does nothing.
    condition     = length(setintersection(toset([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name]), toset(["RUNNER_LABEL", "RUNNER_MACHINE_TYPE"]))) == 0
    error_message = "the environment must not carry RUNNER_LABEL or RUNNER_MACHINE_TYPE, which RUNNER_TIERS replaced"
  }

  assert {
    # The JSON the controller reads has to say what the variable says, tier for tier, not only look right as a string. The instance
    # templates are checked in tests/templates.tftest.hcl.
    condition = { for label, tier in jsondecode([
      for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.value if e.name == "RUNNER_TIERS"
    ][0]) : label => { machine_type = tier.machine_type, boot_disk_gb = tier.boot_disk_gb, max_runners = tier.max_runners } } == { for label, tier in var.runner_tiers : label => { machine_type = tier.machine_type, boot_disk_gb = tier.boot_disk_gb, max_runners = tier.max_runners } }
    error_message = "RUNNER_TIERS must carry every tier of runner_tiers with its machine type, disk size and maximum"
  }

  assert {
    # The controller reads no zone and no single template, because Batch places the VMs and each tier names its own template; a
    # setting here would do nothing.
    condition     = length(setintersection(toset([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name]), toset(["GCP_ZONE", "RUNNER_INSTANCE_TEMPLATE"]))) == 0
    error_message = "the environment must not carry GCP_ZONE or RUNNER_INSTANCE_TEMPLATE, which the controller does not read (github-actions-runner-controller docs/reference/configuration.md)"
  }
}

run "controller_boots_the_stock_image_unless_told_otherwise" {
  command = plan

  assert {
    # Unset, not blank: the controller falls back to its built-in Ubuntu family, which is the state to return to if the baked image
    # is ever the problem (docs/architecture/runner-image.md).
    condition     = !contains([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name], "RUNNER_BOOT_IMAGE")
    error_message = "with boot_baked_image false the service must not carry RUNNER_BOOT_IMAGE"
  }
}

run "controller_boots_the_image_it_is_given" {
  command = plan

  variables {
    boot_baked_image = true
  }

  assert {
    condition = {
      for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name => e.value if length(e.value_source) == 0 && e.name == "RUNNER_BOOT_IMAGE"
    } == { RUNNER_BOOT_IMAGE = "projects/github-runners-prd/global/images/family/gh-runner" }
    error_message = "boot_baked_image must reach the controller as RUNNER_BOOT_IMAGE"
  }

  assert {
    # Adding the variable must not disturb the rest of the contract.
    condition = {
      for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name => e.value if length(e.value_source) == 0 && e.name != "RUNNER_BOOT_IMAGE"
      } == {
      GITHUB_APP_ID              = "1234567"
      GITHUB_APP_INSTALLATION_ID = "89012345"
      GITHUB_ORG                 = "voron-software"
      GITHUB_RUNNER_GROUP_ID     = "3"
      GCP_PROJECT                = "github-runners-prd"
      BATCH_LOCATION             = "europe-west10"
      RUNNER_SERVICE_ACCOUNT     = "runner@github-runners-prd.iam.gserviceaccount.com"
      RUNNER_TIERS               = "{\"gcp-large\":{\"boot_disk_gb\":40,\"instance_template\":\"projects/github-runners-prd/global/instanceTemplates/gh-tier-test-20261108120000000000000001\",\"machine_type\":\"e2-standard-4\",\"max_runners\":1},\"gcp-medium\":{\"boot_disk_gb\":20,\"instance_template\":\"projects/github-runners-prd/global/instanceTemplates/gh-tier-test-20261108120000000000000001\",\"machine_type\":\"e2-standard-2\",\"max_runners\":1}}"
      RUNNER_MAX_RUN_SECONDS     = "21600"
      SWEEP_AUDIENCE             = "https://controller-834662790614.europe-west3.run.app"
      SWEEP_CALLER               = "controller-sweep@github-runners-prd.iam.gserviceaccount.com"
      SWEEP_GRACE_SECONDS        = "90"
      SCALESET_POLL_TIMEOUT_MS   = "1000"
    }
    error_message = "setting boot_baked_image must change no other variable"
  }
}

run "controller_secrets_come_from_secret_manager" {
  command = plan

  assert {
    condition = {
      for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name => one(one(e.value_source).secret_key_ref).secret if length(e.value_source) == 1
      } == {
      GITHUB_APP_PRIVATE_KEY = "github-app-private-key"
      GITHUB_WEBHOOK_SECRET  = "github-webhook-secret"
    }
    error_message = "the private key and the webhook secret must be env vars read from their Secret Manager secrets"
  }

  assert {
    # The version is the number of the secret's newest version (secrets.tf), so that adding a version changes the revision's template
    # and rolls the service. A plan cannot show it: the data source depends on the secrets, which a first plan creates, so the read is
    # deferred and the number is unknown here (and an apply cannot be run, because `prevent_destroy` on the secrets fails the test's
    # clean-up). So this assertion reads what the file says, and the plan of the first apply after a rotation shows the number
    # (gcp-github-runners docs/operations/secret-rotation.md).
    condition     = !strcontains(file("${path.module}/cloudrun.tf"), "\"latest\"") && strcontains(file("${path.module}/cloudrun.tf"), "version = data.google_secret_manager_secret_version.newest[env.key].version")
    error_message = "the secrets must be pinned to the numbered newest version and never to `latest`: only a change of the template starts a new revision, and a running instance keeps the value it started with"
  }

  assert {
    # A destroyed newest version would be pinned and the revision that names it would not start, so the read refuses one. Like the
    # number, the check cannot be evaluated in a plan, and an apply cannot be run (`prevent_destroy` fails the clean-up), so this
    # reads the file. It was shown to fire with an apply-mode run that overrode the data source's destroy_time.
    condition     = strcontains(file("${path.module}/secrets.tf"), "condition     = self.destroy_time == null || self.destroy_time == \"\"")
    error_message = "the read of each secret's newest version must fail when that version is destroyed"
  }

  assert {
    # A payload read would put the key in the state, and the deploy identity may not read one (cloud-iac).
    condition     = alltrue([for k, d in data.google_secret_manager_secret_version.newest : d.fetch_secret_data == false && d.secret == google_secret_manager_secret.controller[k].secret_id])
    error_message = "the newest version of each secret is read as metadata only, and for the secret the controller reads"
  }

  assert {
    condition     = alltrue([for k, b in google_secret_manager_secret_iam_member.controller_accessor : b.role == "roles/secretmanager.secretAccessor" && b.member == google_service_account.controller_runtime.member])
    error_message = "only the controller account reads the secrets, as secretAccessor"
  }

  assert {
    # No secret version resource exists by design (humans add every version, see secrets.tf), so only the bindings are counted.
    condition     = length(google_secret_manager_secret_iam_member.controller_accessor) == 2
    error_message = "both secrets need an accessor binding"
  }
}

run "controller_runs_the_image_it_is_given" {
  command = plan

  assert {
    condition     = google_cloud_run_v2_service.controller[0].template[0].containers[0].image == var.controller_image
    error_message = "the service must run exactly controller_image: nothing else rolls an image out"
  }

  assert {
    condition     = length(google_cloud_run_v2_service.controller[0].template[0].containers) == 1
    error_message = "the service has one container, the controller"
  }
}

run "controller_runs_a_digest_when_given_one" {
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = google_cloud_run_v2_service.controller[0].template[0].containers[0].image == "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "a digest must reach the service as given"
  }
}

run "controller_has_nothing_that_hides_a_change_made_outside" {
  # Nothing but an apply changes the service, so the module ignores no change. A lifecycle block that ignored the image or the
  # client stamps would hide a deploy made with gcloud over this configuration. A test cannot read a lifecycle block, so this reads
  # the file.
  command = plan

  assert {
    condition     = !strcontains(file("${path.module}/cloudrun.tf"), "ignore_changes")
    error_message = "cloudrun.tf must not ignore_changes: the controller image is controller_image, and an apply is the only thing that changes the service"
  }

  assert {
    # The placeholder of the old CI deploy. The service is created with the image it will run.
    condition     = !strcontains(file("${path.module}/cloudrun.tf"), "cloudrun/container/hello")
    error_message = "cloudrun.tf must not carry a placeholder image"
  }
}

run "controller_service_shape" {
  command = plan

  assert {
    condition     = google_cloud_run_v2_service.controller[0].invoker_iam_disabled == true
    error_message = "GitHub cannot present Google credentials, so the invoker check must be off"
  }

  assert {
    condition     = google_cloud_run_v2_service.controller[0].template[0].scaling[0].min_instance_count == 0 && google_cloud_run_v2_service.controller[0].template[0].scaling[0].max_instance_count == 1
    error_message = "the controller must scale to zero and cap at one instance"
  }

  assert {
    condition     = google_cloud_run_v2_service.controller[0].template[0].containers[0].resources[0].limits == tomap({ cpu = "1", memory = "256Mi" })
    error_message = "the controller must get 1 vCPU and 256Mi"
  }

  assert {
    # Cloud Run rejects less than 512Mi with CPU always allocated, so 256Mi needs request-based CPU.
    condition     = google_cloud_run_v2_service.controller[0].template[0].containers[0].resources[0].cpu_idle == true && google_cloud_run_v2_service.controller[0].template[0].containers[0].resources[0].startup_cpu_boost == true
    error_message = "the controller must bill CPU only during requests, and boost CPU at startup"
  }

  assert {
    # Less than 512Mi is allowed only on the first generation.
    condition     = google_cloud_run_v2_service.controller[0].template[0].execution_environment == "EXECUTION_ENVIRONMENT_GEN1"
    error_message = "the controller must run on the first execution environment, which allows 256Mi"
  }

  assert {
    condition     = google_cloud_run_v2_service.controller[0].template[0].service_account == google_service_account.controller_runtime.email
    error_message = "the controller must run as controller-runtime"
  }

  assert {
    condition     = google_cloud_run_v2_service.controller[0].ingress == "INGRESS_TRAFFIC_ALL"
    error_message = "GitHub reaches the controller over the public internet"
  }
}

run "controller_project_roles_are_grantable" {
  command = plan

  assert {
    # github-deploy may grant exactly five project roles (cloud-iac's compute capability); these three are the controller's. Any
    # other role makes the apply fail. compute.viewer is what Batch requires to submit a job that uses an instance template.
    condition     = toset([for k, b in google_project_iam_member.controller_runtime : b.role]) == toset(["roles/batch.jobsEditor", "roles/iam.serviceAccountUser", "roles/compute.viewer"]) && length(google_project_iam_member.controller_runtime) == 3
    error_message = "controller-runtime must hold exactly roles/batch.jobsEditor, roles/iam.serviceAccountUser and roles/compute.viewer"
  }

  assert {
    # Unconditional, because IAM conditions cannot target service accounts; service-accounts.tf records the accepted risk. A
    # condition here would never match and every Batch submit would fail with a 403.
    condition     = alltrue([for k, b in google_project_iam_member.controller_runtime : b.member == google_service_account.controller_runtime.member && length(b.condition) == 0])
    error_message = "the project roles belong to controller-runtime and are unconditional"
  }

  assert {
    # The five roles together are the capability's grantable_roles; any role outside them fails the apply.
    condition = setunion(
      toset([for k, b in google_project_iam_member.controller_runtime : b.role]),
      toset([for k, b in google_project_iam_member.runner : b.role]),
      ) == toset([
        "roles/batch.jobsEditor", "roles/iam.serviceAccountUser", "roles/compute.viewer",
        "roles/batch.agentReporter", "roles/logging.logWriter",
    ])
    error_message = "the project roles in the module must be exactly the five github-deploy may grant"
  }
}

run "webhook_url_points_at_the_webhook_path" {
  command = plan

  assert {
    condition     = endswith(output.webhook_url, "/webhook")
    error_message = "the webhook URL must end in the controller's /webhook endpoint"
  }
}

run "sweep_scheduler_calls_the_controller_as_its_own_account" {
  command = plan

  assert {
    condition     = google_cloud_scheduler_job.sweep[0].schedule == "*/5 * * * *" && google_cloud_scheduler_job.sweep[0].region == "europe-west3"
    error_message = "the sweep must run every five minutes (github-actions-runner-controller docs/architecture/reconcile.md), in the controller's region"
  }

  assert {
    condition     = one(google_cloud_scheduler_job.sweep[0].http_target).http_method == "POST" && one(google_cloud_scheduler_job.sweep[0].http_target).uri == "https://controller-834662790614.europe-west3.run.app/sweep"
    error_message = "the scheduler must POST to the controller's /sweep"
  }

  assert {
    # The controller takes no input on /sweep and refuses a body.
    condition     = one(google_cloud_scheduler_job.sweep[0].http_target).body == null
    error_message = "the scheduler must send no body"
  }

  assert {
    condition     = one(one(google_cloud_scheduler_job.sweep[0].http_target).oidc_token).service_account_email == google_service_account.sweep.email && length(one(google_cloud_scheduler_job.sweep[0].http_target).oauth_token) == 0
    error_message = "the scheduler must send an OIDC ID token of the sweep account, and no OAuth token"
  }

  assert {
    # The controller compares the token's audience and email with its own environment, so the two sides must agree exactly.
    condition = {
      audience = one(one(google_cloud_scheduler_job.sweep[0].http_target).oidc_token).audience
      email    = one(one(google_cloud_scheduler_job.sweep[0].http_target).oidc_token).service_account_email
      } == {
      audience = one([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.value if e.name == "SWEEP_AUDIENCE"])
      email    = one([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.value if e.name == "SWEEP_CALLER"])
    }
    error_message = "the token the scheduler sends must be the one the controller accepts: the same audience and account"
  }

  assert {
    condition     = google_cloud_scheduler_job.sweep[0].attempt_deadline == "60s" && one(google_cloud_scheduler_job.sweep[0].retry_config).retry_count == 0
    error_message = "a sweep gets a minute and no retry, because the next one is five minutes away"
  }

  assert {
    # The URL the audience is made of must be the service's: its name, the project number and its region.
    condition     = startswith(one(one(google_cloud_scheduler_job.sweep[0].http_target).oidc_token).audience, "https://${google_cloud_run_v2_service.controller[0].name}-") && endswith(one(one(google_cloud_scheduler_job.sweep[0].http_target).oidc_token).audience, ".${google_cloud_run_v2_service.controller[0].location}.run.app")
    error_message = "the audience must be the controller service's deterministic URL"
  }
}

run "sweep_account_holds_no_role" {
  command = plan

  assert {
    # Cloud Run's invoker check is off, so the account needs nothing. The module has no other IAM resource than these three (AGENTS.md),
    # so none of them naming the account means it holds no role that the module grants.
    condition = !contains(concat(
      [for k, b in google_project_iam_member.controller_runtime : b.member],
      [for k, b in google_project_iam_member.runner : b.member],
      [for k, b in google_secret_manager_secret_iam_member.controller_accessor : b.member],
    ), google_service_account.sweep.member)
    error_message = "the sweep account must hold no role"
  }
}

run "sweep_grace_reaches_the_controller" {
  command = plan

  variables {
    sweep_grace_seconds = 240
  }

  assert {
    condition     = one([for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.value if e.name == "SWEEP_GRACE_SECONDS"]) == "240"
    error_message = "sweep_grace_seconds must reach the controller as SWEEP_GRACE_SECONDS"
  }
}

run "a_null_setting_takes_the_default" {
  # A root that wraps this module passes its own unset variables, which are null, and must get what the module would have used
  # unset, not a controller environment variable with no value.
  command = plan

  variables {
    runner_max_run_seconds   = null
    sweep_grace_seconds      = null
    scaleset_poll_timeout_ms = null
  }

  assert {
    condition = {
      for e in google_cloud_run_v2_service.controller[0].template[0].containers[0].env : e.name => e.value if contains(["RUNNER_MAX_RUN_SECONDS", "SWEEP_GRACE_SECONDS", "SCALESET_POLL_TIMEOUT_MS"], e.name)
      } == {
      RUNNER_MAX_RUN_SECONDS   = "21600"
      SWEEP_GRACE_SECONDS      = "90"
      SCALESET_POLL_TIMEOUT_MS = "1000"
    }
    error_message = "a null runner_max_run_seconds, sweep_grace_seconds or scaleset_poll_timeout_ms must fall back to the default"
  }
}
