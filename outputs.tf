output "webhook_url" {
  description = "Webhook URL to configure in the GitHub App."
  # The URL is the service's deterministic one (sweep.tf), so it is known before the controller is on, which is when the GitHub
  # App is created.
  value = "${local.controller_url}/webhook"
}

output "controller_service_account" {
  value = google_service_account.controller_runtime.email
}

output "runner_service_account" {
  value = google_service_account.runner.email
}

# What the unit's image build (image/action.yml) and its installation need to name the image the templates boot.
output "image_family" {
  description = "The Compute Engine image family this unit's runner VMs boot when `boot_baked_image` is true, in the unit's project."
  value       = local.image_family
}
