# Instance templates

Each tier of a deployment unit has one global Compute Engine instance template in the unit's project, defined in
`instance-templates.tf`. The
controller puts the template's path in the Batch job, and Batch creates the runner VM from it. The template is where a tier's
machine, disk, image and network tier are defined.

## What a template holds

- The tier's `machine_type`, a `pd-balanced` boot disk of the tier's `boot_disk_gb`, and `scheduling.provisioningModel = SPOT`
  with the `STOP` termination action, because Batch runs the template in a managed instance group and a group refuses Spot VMs
  set to `DELETE`. A stopped VM does not linger: its task fails, and Batch deletes the group when the job ends.
- One network interface on the `default` network and the `default` subnetwork of `batch_location`, with an external IP whose
  access config sets `network_tier = STANDARD`. The subnetwork is a full path, because a bare name is looked up in the provider's
  region and not in `batch_location`. The template's own `region` attribute is left unset: a template is global, and the
  provider reads that attribute back from the subnetwork.
- The `runner` service account with the `cloud-platform` scope (IAM limits what it can do), and the network tag `github-runner`.
- The boot image: the unit's own family when `boot_baked_image` is true, or the stock Ubuntu 24.04 family. The template names the
  family and not an image, so a rebuilt image is picked up by the next VM without a template change
  ([Runner image](runner-image.md)).

## Why instance templates

The runner VMs' internet egress would be billed at the Premium network tier. The project's default tier is `STANDARD`, but Cloud
Batch writes `networkTier: PREMIUM` explicitly into every instance template and every instance it creates, and a tier set on a
resource takes precedence over the project default.

Batch gives the job no way to say otherwise: `NetworkInterface` has `network`, `subnetwork`, `nicType` and `noExternalIpAddress`
and no tier and no access config, in `v1` and in `v1alpha`. The one lever is
`AllocationPolicy.instances[].instanceTemplate`, a Compute Engine instance template whose access config sets `STANDARD`. Batch's
rules for it, from the REST reference (`InstancePolicyOrTemplate`, `AllocationPolicy`) and from
<https://cloud.google.com/batch/docs/create-run-job-vm-template>:

- An entry holds an `InstancePolicy` or an `instanceTemplate`, not both. So the machine, provisioning model, disk, image and
  network all move from the controller's job into the template.
- The template must be in the job's project. A global template may be named `projects/<project>/global/instanceTemplates/<name>`.
- With a template, Batch uses the template's network settings instead of `allocationPolicy.network`.
- `allocationPolicy.serviceAccount` must match the service account in any template used. The OpenTofu sets both from the
  `runner` account, and a mismatch is a Batch error at submit.
- Whoever submits the job needs `roles/compute.viewer` on the template. It is granted on the project, because a grant on a
  template needs `compute.instanceTemplates.setIamPolicy`, which `github-deploy` does not hold.

Three things are not in Batch's documentation, and the design depends on them:

- With a template the job cannot set `provisioningModel`, so Spot is expected to come from the template's
  `scheduling.provisioningModel`. An on-demand VM instead of a Spot one would cost more than the tier saves.
- Batch writes its own `PREMIUM` into the templates it makes. That it keeps the tier of a template it is given is expected and not
  known.
- The job's `tags` are documented for "the VM instances", not for ones made from a template. The deny-all-ingress rule depends on
  the tag, so the template has `github-runner` as well.

How to check all three on a running VM is in
Deploys (gcp-github-runners, `docs/operations/deploys.md`). If the tier turns out to be `PREMIUM`, the templates
achieve nothing and this section is to be rewritten.

## The controller's side

An entry of `RUNNER_TIERS` has an optional `instance_template`, the template's path
`projects/<project>/global/instanceTemplates/<name>`, and the OpenTofu gives every tier one. The controller checks only the form
of the path at start-up and refuses a malformed one. That the template exists, is in the job's project and is readable by the
controller is Batch's to say when the job is created. `machine_type` and `boot_disk_gb` stay required and validated in
`RUNNER_TIERS`, so that the template's inputs are written in one place, and the controller does not send them while a tier has a
template. See [Tiers](../reference/tiers.md) and Batch jobs (github-actions-runner-controller, `docs/architecture/batch-jobs.md`).

`RUNNER_BOOT_IMAGE` is still read, for a tier without a template, and the module sets it to the same image as the
templates, so the two cannot name different images. Setting `boot_baked_image` to false returns every tier to the stock image by replacing
the templates.

Target state: `instance_template` is required, the inline policy and `RUNNER_BOOT_IMAGE` are removed from the controller, and
the OpenTofu stops setting the variable.

## Immutability

A template cannot be changed, so a change to a tier replaces its template. The template resource has a `name_prefix` and
`create_before_destroy`, and a test fails if either goes. The new template's path becomes the tier's `instance_template`, which is
a new Cloud Run revision. A job that Batch accepted before the swap and has not yet provisioned names the old template, so
deleting it in that window fails that job's VM. The window is Batch's scheduling delay, one to three minutes.

The template is named `gh-tier-<unit>-<label>-` plus the 26 characters Terraform appends, and Compute Engine caps a name at 63. A
longer prefix makes the provider shorten the suffix and risk a collision, so the validation in `variables.tf` refuses a tier label
longer than 28 characters. The controller accepts labels up to 39.

The `vmimages` name rules ([Runner image](runner-image.md#who-may-do-what)) scope instances, disks and images. A template is
another resource type, so neither the `gh-image-*` nor the `gh-runner-*` rule applies to it and neither is widened.

## Why not the project default tier

Setting the project's default network tier to `STANDARD` does not change the VMs: Batch sets a tier on every instance, and the
instance's wins.

## Why not Cloud NAT

A NAT gateway would let the VMs go without an external IP, so no tier would apply. It costs about $32 a month plus $0.045 per GiB
processed, and the whole runner bill for the day it was measured was $1.83. The VMs keep an external IP, with the `STANDARD` tier
and no inbound access.

## Why pd-balanced and not pd-ssd

IO-bound steps ran 1.5 to 1.7 times slower than on GitHub-hosted runners, and `pd-ssd` was measured: about 7% faster on IO-bound
steps (tests 296 s to 274 s, Playwright unchanged), which does not justify the price. The remaining gap to GitHub-hosted runners
is the E2 CPU.
