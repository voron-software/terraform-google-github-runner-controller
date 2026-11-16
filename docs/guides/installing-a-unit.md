# Installing a unit

How to install a deployment unit for a GitHub organisation: a project, an OpenTofu root that calls the module, a GitHub App, a
runner group, the two secret versions and an image build. Each step that changes the root is a pull request that the
installation's apply workflow applies. The organisation below is `acme-org`; replace it.

OpenTofu adds no secret version, and a controller cannot start without both, so the unit is created with its controller off, a
person adds the versions, and a second apply turns it on.

1. **Project.** Create a project for the unit, with the APIs, the network and a deployer that holds the roles in
   [Deployer requirements](../reference/deployer-requirements.md). If the controller image is in another project's registry, its
   publisher grants the unit's Cloud Run service agent and deployer read access to it
   ([What the publisher grants](../reference/deployer-requirements.md#what-the-publisher-grants)).
2. **Create the unit, controller off.** Call the module from the installation's root, with the GitHub ids at `0` until they exist:

   ```hcl
   module "unit" {
     source = "git::ssh://git@github.com/voron-software/terraform-google-github-runner-controller.git?ref=v<X.Y.Z>"

     controller_enabled = false

     project_id                 = "acme-runners"
     location                   = "europe-west3"
     batch_location             = "europe-west10"
     github_org                 = "acme-org"
     github_app_id              = 0
     github_app_installation_id = 0
     github_runner_group_id     = 0
     controller_image           = "europe-west3-docker.pkg.dev/<publisher>/cloudrun/controller:v<X.Y.Z>"
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
3. **Image build.** Add a workflow that authenticates to Google Cloud as the deployer and runs the image action of the same release
   as the module, on `ubuntu-latest` and on a schedule, weekly for ours:

   ```yaml
   - uses: voron-software/terraform-google-github-runner-controller/image@v<X.Y.Z>
     with:
       project-id: acme-runners
       zone: europe-west10-b
   ```

   The zone is in `batch_location`. Run it once now; it builds the family `gh-runner` ([Runner image](../architecture/runner-image.md)).
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
