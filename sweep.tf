# The periodic reconcile: Cloud Scheduler calls the controller's POST /sweep every five minutes, which reconciles every tier with its
# runner scale set (gcp-runner-controller docs/architecture/reconcile.md). It is the backstop for a lost webhook, and what notices a job GitHub
# reassigned without sending one.
#
# Needs the Cloud Scheduler API (cloudscheduler.googleapis.com) enabled and the right to manage scheduler jobs. In our deployment
# those are the `cloudscheduler` capability in cloud-iac, our platform repository, and without it the job below fails the apply
# with a 403 while the rest still applies.

# The controller's URL, worked out instead of read from the service. The service's environment carries it as SWEEP_AUDIENCE, so
# reading `google_cloud_run_v2_service.controller.uri` here would make the service depend on itself. Cloud Run gives every
# service this deterministic URL next to the hashed one, and either reaches it. The audience is only compared as a string, so
# what matters is that the scheduler and the controller use the same one, and both use this.
data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # A local and not the resource's `name`, which the service's own environment could not refer to either.
  controller_service = "${local.name_prefix}controller"
  controller_url     = "https://${local.controller_service}-${data.google_project.this.number}.${var.location}.run.app"
}

# The identity Cloud Scheduler signs its ID token as. It holds no role: Cloud Run's invoker check is off, so there is nothing to
# grant, and the controller accepts its token by its email alone. Creating the job needs actAs on it, which the deploy identity
# has on every account in the project (service-accounts.tf).
resource "google_service_account" "sweep" {
  account_id   = "${local.name_prefix}controller-sweep"
  display_name = "Runner controller sweep caller"
  project      = var.project_id
}

resource "google_cloud_scheduler_job" "sweep" {
  name        = "${local.name_prefix}sweep-idle-runners"
  description = "Reconciles every runner tier with its scale set (gcp-runner-controller docs/architecture/reconcile.md)."
  project     = var.project_id
  region      = var.location
  # Every five minutes (gcp-runner-controller docs/architecture/reconcile.md, "The sweep, every five minutes"): a job whose webhook was lost, or that GitHub assigned again, waits at most this long for its
  # runner when no other webhook of its tier comes, and five minutes is how long GitHub itself waits before it assigns a job again.
  schedule  = "*/5 * * * *"
  time_zone = "Etc/UTC"
  # A reconcile is a session and a short poll per tier, two listings and a few calls; a minute is ample, and Cloud Scheduler's least
  # for an HTTP target is 15 seconds.
  attempt_deadline = "60s"

  # The next run repeats the whole reconcile, and a webhook reconciles its tier sooner, so a retry would add nothing.
  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = "${local.controller_url}/sweep"

    oidc_token {
      service_account_email = google_service_account.sweep.email
      audience              = local.controller_url
    }
  }
}
