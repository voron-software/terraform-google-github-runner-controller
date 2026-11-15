locals {
  # Environment variable the controller reads -> Secret Manager secret id. The real versions are added by hand by a secret
  # operator, never by Terraform, so the values stay out of state:
  # `printf '%s' "$VALUE" | gcloud secrets versions add <id> --data-file=- --project=<project>`. See gcp-github-runners docs/operations/adding-a-unit.md.
  controller_secrets = {
    GITHUB_APP_PRIVATE_KEY = "github-app-private-key"
    GITHUB_WEBHOOK_SECRET  = "github-webhook-secret"
  }
}

resource "google_secret_manager_secret" "controller" {
  for_each = local.controller_secrets

  secret_id = each.value
  project   = var.project_id

  replication {
    auto {}
  }

  # Destroying a secret destroys every version a person added by hand, and no apply can bring those back. This turns a plan
  # that replaces or drops a secret into an error. It cannot see a secret whose whole block is gone, so our installation's `IaC`
  # workflow also refuses any plan that deletes without replacing (gcp-github-runners docs/operations/deploys.md#plans-that-delete).
  lifecycle {
    prevent_destroy = true
  }
}

# Terraform manages no secret version. A version it creates is tracked in state, so when a human destroys it the next apply
# recreates it as a newer version, which `latest` then serves. Humans add every version.

# The number of each secret's newest version, which the service pins instead of `latest` (cloudrun.tf).
#
# Cloud Run resolves a secret exposed as an environment variable when an instance starts, not while it runs: "Environment variables
# are resolved at instance startup time" (https://docs.cloud.google.com/run/docs/configuring/services/secrets), which also recommends
# pinning a version for that reason. With `latest`, a new version reaches the service only when a new instance starts. The sweep
# calls the controller every five minutes and an idle instance is kept for 15 minutes at most
# (https://docs.cloud.google.com/run/docs/container-contract, "Idle"), so the service in practice never scales to zero, and the
# running instance would wait for Cloud Run to replace it, which it may do at any time and promises never. A new revision starts
# new instances, and any change to the revision's template makes one ("Any configuration change leads to the creation of a new
# revision", on the first page). With the number pinned, adding a version changes the template at the next apply, so the apply
# is the rotation, the plan shows it, and nothing outside OpenTofu changes a field it owns. The numbers are derived here and never
# written in a tfvars file, so no one has to remember to bump one.
#
# Metadata only (`fetch_secret_data = false`, which needs `secretmanager.versions.get` and not `versions.access`): the applying
# identity may not read a payload in our deployment (cloud-iac excludes secretmanager.versions.access), and a payload read would put
# the key in the state. The read fails while the secret has no version, as the service would (cloudrun.tf, `depends_on`).
data "google_secret_manager_secret_version" "newest" {
  # Read only for the service that pins it: a secret with no version fails this read, and so the plan, which is what the controller
  # being off is for while a person adds the first versions.
  for_each = var.controller_enabled ? google_secret_manager_secret.controller : {}

  project           = var.project_id
  secret            = each.value.secret_id
  fetch_secret_data = false

  # The provider takes whatever `latest` names and reports it as enabled, so a version that was destroyed would be pinned and the
  # revision that names it would not start. A destroyed version has a destroy time, which is the one thing that can be seen here.
  # A version that is only disabled cannot: the provider does not read the state, so the plan passes and the revision fails to start
  # (gcp-github-runners docs/operations/secret-rotation.md says to leave no disabled version newest).
  lifecycle {
    postcondition {
      condition     = self.destroy_time == null || self.destroy_time == ""
      error_message = "The newest version of the secret has been destroyed, so a revision that pins it cannot start. Add a version, which becomes the newest, and apply again."
    }
  }
}

# Per secret, not per project: the controller reads exactly these two. A deploy identity that may not write project-level IAM
# (`github-deploy` in our deployment) may still write secret-level IAM.
resource "google_secret_manager_secret_iam_member" "controller_accessor" {
  for_each = google_secret_manager_secret.controller

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.controller_runtime.member
}
