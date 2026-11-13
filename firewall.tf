# Denies every inbound connection to a runner VM and to the VM that builds the runners' image. The runner dials out to GitHub and
# needs nothing inbound, but the default network ships with allow rules for SSH, RDP and ICMP from anywhere (priority 65534), and a
# job's own code runs on the VM. A deny at priority 100 wins over those without touching them, and the tags keep it off any other
# VM in the project. The controller puts `github-runner` on every VM through the Batch job's allocation policy (gcp-runner-controller docs/architecture/batch-jobs.md); image/action.yml
# puts `gh-image` on its build VM (docs/architecture/runner-image.md), which runs third-party installers and needs no inbound either. The legacy unit's rule
# keeps its name without a prefix because renaming a firewall rule replaces it.
resource "google_compute_firewall" "deny_runner_ingress" {
  name      = "${local.name_prefix}gh-runner-deny-ingress"
  project   = var.project_id
  network   = "default"
  direction = "INGRESS"
  priority  = 100

  # TODO: remove `gh-runner` later. It was the runner VMs' tag before `github-runner`, and VMs made from the old templates keep it
  # until their Batch jobs end.
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["github-runner", "gh-runner", "gh-image"]

  deny {
    protocol = "all"
  }
}
