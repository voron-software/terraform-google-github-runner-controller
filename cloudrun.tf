# The controller: keeps each tier's Cloud Batch jobs, one per runner VM (github-actions-runner-controller docs/architecture/batch-jobs.md), at the number of jobs GitHub has assigned to the
# tier's runner scale set (github-actions-runner-controller docs/architecture/reconcile.md). A `workflow_job` webhook reconciles the job's tier, the scheduler (sweep.tf) every tier.
# The image is `controller_image`, a pinned release, so an apply is the only thing that rolls the service out or changes it. Nothing
# here ignores a change made from outside, such as a `gcloud run deploy`, which the next apply would undo. The names of the
# environment variables are the contract with github-actions-runner-controller (its docs/reference/configuration.md).
resource "google_cloud_run_v2_service" "controller" {
  # Off while a new unit waits for its secret versions (variables.tf, `controller_enabled`).
  count = var.controller_enabled ? 1 : 0

  name     = local.controller_service
  location = var.location
  project  = var.project_id
  ingress  = "INGRESS_TRAFFIC_ALL"

  # GitHub cannot present Google credentials, and an organisation's domain restricted sharing policy rejects an `allUsers` invoker
  # binding, as ours does. Turning the invoker check off is the supported way to serve such callers; the controller authenticates
  # every request itself instead: a webhook by its HMAC signature, a sweep by Cloud Scheduler's Google ID token (sweep.tf). See the
  # `cloudrun` capability and seed/org-policies.tf in cloud-iac, our platform repository.
  invoker_iam_disabled = true

  # Stateless and recreated from this configuration, so protection would only block fixing a service that failed to start.
  deletion_protection = false

  template {
    service_account = google_service_account.controller_runtime.email

    # Pinned because the 256Mi set below is allowed only on the first generation (the second needs 512Mi), and left unspecified
    # Cloud Run picks a generation by the features in use.
    execution_environment = "EXECUTION_ENVIRONMENT_GEN1"

    # Exactly one instance at most: GitHub allows one message session per scale set, and the reconcile serialises each tier with
    # an in-process lock, so a second instance would make the two conflict over sessions and could start a tier's runners twice.
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      # Pinned by the caller (variables.tf), and the image must exist when the apply runs: Cloud Run refuses a revision whose image
      # it cannot pull. A caller that has no build pipeline gets one from a release (github-actions-runner-controller docs/operations/releases.md), so there is no
      # placeholder to create the service with and replace later.
      image = var.controller_image

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
        # CPU only while a request is in flight, which is all the controller does: every reconcile runs inside a webhook's or the
        # scheduler's request (github-actions-runner-controller docs/architecture/scale-sets.md, "Why not long-lived pollers"). The alternative bills an instance for its whole life, and this service exists to cost
        # nothing while no job is queued. Cloud Run also rejects less than 512Mi with
        # CPU always allocated, so the small memory above depends on this.
        cpu_idle = true
        # The first request after scale-to-zero starts the instance while GitHub waits for a response.
        startup_cpu_boost = true
      }

      env {
        name  = "GITHUB_APP_ID"
        value = tostring(var.github_app_id)
      }
      env {
        name  = "GITHUB_APP_INSTALLATION_ID"
        value = tostring(var.github_app_installation_id)
      }
      env {
        name  = "GITHUB_ORG"
        value = var.github_org
      }
      env {
        name  = "GITHUB_RUNNER_GROUP_ID"
        value = tostring(var.github_runner_group_id)
      }
      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "BATCH_LOCATION"
        value = var.batch_location
      }
      env {
        name  = "RUNNER_SERVICE_ACCOUNT"
        value = google_service_account.runner.email
      }
      # One JSON object, because the tiers are a map and an environment variable is a string. Keys come out sorted, which is
      # why the controller keeps no order of its own to depend on. Each tier also names its instance template (instance-templates.tf)
      # by the path form the controller accepts, `projects/<project>/global/instanceTemplates/<name>`, and not the template's
      # `self_link`, which is a URL the controller refuses.
      env {
        name = "RUNNER_TIERS"
        value = jsonencode({
          for label, tier in var.runner_tiers : label => merge(tier, {
            instance_template = "projects/${var.project_id}/global/instanceTemplates/${google_compute_instance_template.runner[label].name}"
          })
        })
      }
      env {
        name  = "RUNNER_MAX_RUN_SECONDS"
        value = tostring(var.runner_max_run_seconds)
      }
      # Who may call POST /sweep: the audience and the account of Cloud Scheduler's ID token, the same values the scheduler job
      # in sweep.tf is given. The URL is the computed one, because this service's own `uri` cannot be one of its inputs.
      env {
        name  = "SWEEP_AUDIENCE"
        value = local.controller_url
      }
      env {
        name  = "SWEEP_CALLER"
        value = google_service_account.sweep.email
      }
      env {
        name  = "SWEEP_GRACE_SECONDS"
        value = tostring(var.sweep_grace_seconds)
      }
      env {
        name  = "SCALESET_POLL_TIMEOUT_MS"
        value = tostring(var.scaleset_poll_timeout_ms)
      }

      # Only when set: an empty value would read as unset anyway, but leaving the variable out says plainly that the controller is
      # on its built-in stock image. No tier reads it now, because every tier has an instance template that names its own image
      # (instance-templates.tf); it stays until the controller stops reading it (docs/architecture/instance-templates.md, "The controller's side").
      dynamic "env" {
        for_each = var.boot_baked_image ? [local.runner_image] : []

        content {
          name  = "RUNNER_BOOT_IMAGE"
          value = env.value
        }
      }

      dynamic "env" {
        for_each = google_secret_manager_secret.controller

        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret = env.value.secret_id
              # The newest version's number and not `latest`, so a rotation changes the revision's template, which is what makes
              # Cloud Run start new instances that read it (secrets.tf).
              version = data.google_secret_manager_secret_version.newest[env.key].version
            }
          }
        }
      }
    }
  }

  # A revision that cannot read its secrets fails to deploy, so the accessor bindings must exist first. It also fails while a
  # secret has no version, and Terraform adds none (secrets.tf). A unit is therefore created with the controller off
  # (variables.tf, `controller_enabled`), a secret operator adds the versions, and turning it on creates the service
  # (docs/guides/installing-a-unit.md).
  #
  # The project roles are in the list for a similar reason: a revision that sends jobs with an instance template must not be rolled
  # out before the controller holds `roles/compute.viewer`, which Batch requires of whoever submits such a job.
  depends_on = [
    google_secret_manager_secret_iam_member.controller_accessor,
    google_project_iam_member.controller_runtime,
  ]
}
