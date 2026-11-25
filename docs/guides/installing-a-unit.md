# Installing a unit

How to install a deployment unit for a GitHub organisation: a project, an OpenTofu root that calls the module, a GitHub App, a
runner group, the two secret versions and an image build. Each step that changes the root is applied with `tofu apply`, by hand or
by whatever pipeline applies the root. The organisation below is `acme-org`; replace it.

OpenTofu adds no secret version, and a controller cannot start without both, so the unit is created with its controller off, a
person adds the versions, and a second apply turns it on.

## Before you start

- **Quota.** Each runner VM is a Spot VM with an external IPv4 address, because a NAT gateway for the runners was rejected on cost
  ([Why not Cloud NAT](../architecture/instance-templates.md#why-not-cloud-nat)). The project's Compute Engine quotas therefore cap
  how many jobs run at once, whatever each tier's `max_runners` says: `IN_USE_ADDRESSES` in `batch_location` (one per running VM,
  the image build VM included) and `CPUS_ALL_REGIONS` (the vCPUs of every running VM), besides the regional vCPU quota. A new
  project's quotas may be low: with 4 addresses and 12 vCPUs, at most 4 two-vCPU jobs run at once, and fewer while an image build
  runs. A job that cannot get quota waits in Batch instead of failing, so too little quota shows up as queueing and not as errors.
  Look at the limits, and ask for an increase of addresses and vCPUs together before the first real load
  ([Quota](../reference/tiers.md#quota) has how the tiers share them):

  ```bash
  gcloud compute regions describe europe-west10 --project acme-runners --flatten=quotas \
    --format='table(quotas.metric,quotas.limit,quotas.usage)'
  gcloud compute project-info describe --project acme-runners --flatten=quotas \
    --format='table(quotas.metric,quotas.limit,quotas.usage)'
  ```

- **The controller image.** The module deploys a controller image that it does not build, pinned by `controller_image`. Cloud Run
  must be able to pull it when the controller is turned on (step 7).

## Steps

1. **Project.** Create a project for the unit, with the APIs, the network and a deployer that holds the roles in
   [Deployer requirements](../reference/deployer-requirements.md). If the controller image is in another project's registry, whoever
   owns that registry grants the unit's Cloud Run service agent and deployer read access to it
   ([What the registry owner grants](../reference/deployer-requirements.md#what-the-registry-owner-grants)).
2. **Create the unit, controller off.** Call the module from the unit's root, with the GitHub ids at `0` until they exist:

   ```hcl
   module "unit" {
     source = "git::https://github.com/voron-software/terraform-google-github-runner-controller.git?ref=v<X.Y.Z>"

     controller_enabled = false

     project_id                 = "acme-runners"
     location                   = "europe-west3"
     batch_location             = "europe-west10"
     github_org                 = "acme-org"
     github_app_id              = 0
     github_app_installation_id = 0
     github_runner_group_id     = 0
     controller_image           = "europe-west3-docker.pkg.dev/<registry-project>/cloudrun/controller:v<X.Y.Z>"
     runner_tiers = {
       gcp-small = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 2 }
     }
   }

   output "webhook_url" {
     value = module.unit.webhook_url
   }
   ```

   Apply. It creates the unit's accounts, secrets (with no versions), firewall rule and instance templates, and prints the webhook
   URL, which is known before the controller exists.
3. **Image build.** Add a workflow that authenticates to Google Cloud as the deployer (for example with
   `google-github-actions/auth` and workload identity federation) and runs the image action of the same release as the module. It
   runs on a GitHub-hosted runner, which has the `gcloud` CLI, and on a schedule, weekly for instance:

   ```yaml
   - uses: voron-software/terraform-google-github-runner-controller/image@v<X.Y.Z>
     with:
       project-id: acme-runners
       zone: europe-west10-b
   ```

   The deployer needs the roles in [Deployer requirements](../reference/deployer-requirements.md) that create and delete instances,
   disks and images. The zone is in `batch_location`. Run it once now; it builds the family `gh-runner` ([Runner image](../architecture/runner-image.md)).
4. **GitHub App.** In `acme-org`'s settings, create a GitHub App:
   - Webhook: active, with the URL from step 2 and a secret generated now and kept for step 6
     (`WEBHOOK_SECRET="$(openssl rand -hex 32)"`). Nothing answers yet, so GitHub's deliveries fail until step 7.
   - Organization permission "Self-hosted runners": read and write. The controller creates the scale sets and mints their runners
     with it.
   - Repository permission "Actions": read-only. GitHub requires it to offer the `workflow_job` event.
   - Subscribe to the `workflow_job` event.
   - Where it can be installed: only this account.

   Generate a private key (a `.pem` download), install the App on the organisation with access to the same private repositories as
   the runner group below, and note the App ID and the installation id (the last segment of the installation's settings URL).
5. **Runner group.** Create an organisation runner group restricted to the chosen private repositories, with public repositories
   not allowed, and note its id:

   ```bash
   gh api orgs/acme-org/actions/runner-groups
   ```

6. **Secrets.** Someone who can add secret versions without reading them (`roles/secretmanager.secretVersionAdder`) adds the first
   version of both secrets:

   ```bash
   gcloud secrets versions add github-app-private-key --project acme-runners --data-file=app.pem
   printf '%s' "$WEBHOOK_SECRET" | gcloud secrets versions add github-webhook-secret --project acme-runners --data-file=-
   unset WEBHOOK_SECRET
   ```

   Delete the local `.pem` afterwards. The module manages no version, so no later apply replaces or recreates one.
7. **Turn the controller on.** Put the three ids in the module call, remove `controller_enabled = false` and apply. The apply
   creates the controller service, pinned to the newest version of each secret, and its sweep.
8. **Boot the baked image.** Once the family has an image:

   ```bash
   gcloud compute images describe-from-family gh-runner --project acme-runners --format='value(name,status)'
   ```

   set `boot_baked_image = true` and apply. Until then the VMs boot the stock Ubuntu image, on which the controller's VM script
   installs Docker and the runner at every boot. A family with no image gives every job a VM that cannot be created, which is why
   this waits.
9. **Check.** In a private repository of the runner group, run a job with `runs-on: gcp-small`. The job gets a VM within a minute
   or two, and the VM is deleted when the job ends.
