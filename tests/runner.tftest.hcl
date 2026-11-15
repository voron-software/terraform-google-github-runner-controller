# The runner side of github-actions-runner-controller docs/architecture/batch-jobs.md: what protects a runner VM and what its identity can do. The VM itself is created by Cloud Batch
# from the instance template of the tier (tests/templates.tftest.hcl). Runs against a mock google provider (no credentials).
mock_provider "google" {}

# The mock fills computed values with random strings, which the provider's own validation rejects for IAM members.
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

variables {
  # The legacy unit, whose names are the ones these tests were written against; tests/units.tftest.hcl covers a named unit.
  name                       = "prd"
  legacy_names               = true
  project_id                 = "github-runners-prd"
  location                   = "europe-west3"
  batch_location             = "europe-west10"
  github_org                 = "voron-software"
  github_app_id              = 1
  github_app_installation_id = 2
  github_runner_group_id     = 3
  controller_image           = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0"
  runner_tiers = {
    gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
  }
}

run "firewall_denies_all_ingress_to_runners" {
  command = plan

  assert {
    # github-runner is on the Batch VMs (gh-runner on those made from the templates before it), gh-image on the VM the image
    # workflow builds the runners' image on (docs/architecture/runner-image.md).
    condition     = google_compute_firewall.deny_runner_ingress.direction == "INGRESS" && google_compute_firewall.deny_runner_ingress.target_tags == toset(["github-runner", "gh-runner", "gh-image"])
    error_message = "the rule must apply to inbound traffic to the github-runner, gh-runner and gh-image tags only"
  }

  assert {
    condition     = length(google_compute_firewall.deny_runner_ingress.deny) == 1 && one(google_compute_firewall.deny_runner_ingress.deny).protocol == "all" && length(google_compute_firewall.deny_runner_ingress.allow) == 0
    error_message = "the rule must deny every protocol and allow nothing"
  }

  assert {
    condition     = google_compute_firewall.deny_runner_ingress.source_ranges == toset(["0.0.0.0/0"])
    error_message = "the rule must cover every source address"
  }

  assert {
    # The default network's allow-ssh, allow-rdp and allow-icmp rules are at 65534.
    condition     = google_compute_firewall.deny_runner_ingress.priority < 65534
    error_message = "the deny rule must outrank the default network's allow rules"
  }

  assert {
    # Batch VMs are created on the default network, which is where the rule applies.
    condition     = google_compute_firewall.deny_runner_ingress.network == "default"
    error_message = "the rule must be on the default network, where Batch creates the VMs"
  }
}

run "runner_account_holds_exactly_the_batch_roles" {
  command = plan

  assert {
    # Batch requires both of every task account. A job can read this account's token, so there must be nothing else.
    condition     = toset([for k, b in google_project_iam_member.runner : b.role]) == toset(["roles/batch.agentReporter", "roles/logging.logWriter"]) && length(google_project_iam_member.runner) == 2
    error_message = "the runner account must hold exactly roles/batch.agentReporter and roles/logging.logWriter"
  }

  assert {
    condition     = alltrue([for k, b in google_project_iam_member.runner : b.member == google_service_account.runner.member && length(b.condition) == 0 && b.project == "github-runners-prd"])
    error_message = "the runner account's roles are unconditional project roles of the runner account itself"
  }

  assert {
    condition     = length([for k, b in google_project_iam_member.controller_runtime : k if b.member == google_service_account.runner.member]) == 0
    error_message = "no controller binding may name the runner account"
  }

  assert {
    condition     = length([for k, b in google_secret_manager_secret_iam_member.controller_accessor : k if b.member == google_service_account.runner.member]) == 0
    error_message = "the runner account must not read any secret"
  }
}
