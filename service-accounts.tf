# The module is applied by an identity that can act as every service account in the project, which creating a Batch job or a
# scheduler job as one of them needs, but cannot write service account IAM policies. In our deployment that is `github-deploy`
# (gcp-github-runners docs/architecture/installation.md#what-cloud-iac-provides). So nothing here grants anyone access to an account; every grant below
# is on the project or on a secret.
resource "google_service_account" "controller_runtime" {
  account_id   = "controller-runtime"
  display_name = "Runner controller runtime"
  project      = var.project_id
}

resource "google_service_account" "runner" {
  account_id   = "runner"
  display_name = "Runner VM"
  project      = var.project_id
}

# The controller submits and deletes Batch jobs, and has to attach the `runner` account to each. All three roles are among the five
# project roles that `github-deploy` may grant in our deployment: the grant is condition-scoped to exactly those five, so any
# other role here fails the apply with a 403 instead of widening access, and a new role means a change to the project's platform
# repository first (gcp-github-runners docs/architecture/installation.md#what-cloud-iac-provides).
#
# `roles/compute.viewer` is for the instance templates (instance-templates.tf): Batch requires whoever submits a job that uses a
# template to be able to read it (https://docs.cloud.google.com/batch/docs/create-run-job-vm-template). It is on the project and not
# on the templates because a grant on a template needs `compute.instanceTemplates.setIamPolicy`, which an identity limited as above
# does not hold. It is read-only, and the controller's `roles/batch.jobsEditor` already reads job specs.
resource "google_project_iam_member" "controller_runtime" {
  for_each = toset([
    "roles/batch.jobsEditor",
    "roles/iam.serviceAccountUser",
    "roles/compute.viewer",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.controller_runtime.member
}

# Accepted risk: a project-level `iam.serviceAccountUser` lets the controller act as every service account in the project, not
# only `runner`. That includes the deploy identity, so a compromised controller could submit a Batch job that runs as it. It cannot
# be narrowed from here. The deploy identity cannot write service account IAM policies, so the grant cannot sit on the `runner`
# account, and an IAM condition cannot target service accounts: they are not among the resource types that recognize resource
# attributes (https://docs.cloud.google.com/iam/docs/conditions-resource-attributes). The tighter design is for the platform
# repository to own the `runner` account and bind actAs on it alone (docs/architecture/security-model.md).

# Batch requires both of these of the service account every task runs as: the first lets the agent on the VM report the task's
# state, the second lets it write the task's logs. Nothing else is granted, on purpose. A job runs arbitrary code on the VM,
# and that code can ask the metadata server for this account's token, so the token may write log entries and report task
# state and open nothing else: no VM, no secret, no data. Give this account another role and every workflow in the runner
# group inherits it.
resource "google_project_iam_member" "runner" {
  for_each = toset([
    "roles/batch.agentReporter",
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.runner.member
}
