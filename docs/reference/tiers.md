# Tiers

A tier is a label that a job lists in `runs-on` and the machine that serves it. `RUNNER_TIERS` holds all of them as one JSON
object, which the module builds with `jsonencode` from its map variable `runner_tiers`. Each deployment unit sets its own; the table
below is the voron-software unit's, in gcp-github-runners:

```json
{"gcp-medium": {"machine_type": "e2-standard-2", "boot_disk_gb": 20, "max_runners": 2}, "gcp-large": {"machine_type": "e2-standard-4", "boot_disk_gb": 40, "max_runners": 1}}
```

| Label | Machine | vCPU | Memory | Boot disk | Max runners | For |
|---|---|---|---|---|---|---|
| `gcp-small` | `e2-medium` | 2 (shared) | 4 GB | 20 GB | 4 | Lint, formatting, validation. Not `cargo`: 4 GB is too little to link a workspace |
| `gcp-medium` | `e2-standard-2` | 2 | 8 GB | 20 GB | 4 | The default: tests, `docker build`, small Rust crates |
| `gcp-large` | `e2-standard-4` | 4 | 16 GB | 40 GB | 2 | Rust workspace builds and tests |
| `gcp-xlarge` | `e2-standard-8` | 8 | 32 GB | 80 GB | 1 | The heaviest builds |

`max_runners` is the most runners of the tier at once, booting, idle or busy. The reconcile never starts one past it, and it is
sent to GitHub as the scale set's capacity. A job beyond it waits on GitHub's side until a runner of the tier is free.

## Rules

`RUNNER_TIERS` is required and is parsed once at start-up by `tier::Tiers::parse` in gcp-runner-controller's
`crates/controller/src/tier.rs`. A value that breaks a rule stops the process, and the message names the variable and the tier. The
variable `runner_tiers` in `variables.tf` repeats the rules, so a bad value fails the plan first. The two are in different
repositories, so a change to a rule is made in both.

| Rule | Why |
|---|---|
| At least one tier | Nothing could be served |
| Label is 1 to 39 lowercase letters, digits and `-`, and neither starts nor ends with `-` | The label is also the name and a label of the tier's scale set, the value of the `gh-tier` label on the Batch job and its VMs, and part of each runner's name, `runner-<label>-<16 hex digits>`, which names its Batch job. Batch caps a job name at 63 characters, which leaves 39 for the label, and a dash at either end would give names the controller does not read as its own. Lowercase only, because GitHub compares labels without regard to case and a second spelling could only collide |
| In the module only: label is at most 28 characters, less the unit's prefix | The controller takes up to 63. Each tier's instance template is named `gh-tier-<unit>-<label>-` plus the 26 characters Terraform appends, and Compute Engine caps a name at 63. With a longer prefix the provider shortens the suffix and risks two templates getting one name, so the validation in `variables.tf` stops the label at 28 and a precondition in `instance-templates.tf` holds the whole prefix to 37 |
| Label is not `self-hosted` | Every self-hosted runner holds it, so as one tier's label it would claim every self-hosted job |
| Labels are pairwise different, ignoring case | Two tiers with one label could not be told apart |
| Machine type is lowercase letters, digits and `-` | It goes into the Batch request, as the project and location do |
| Boot disk is a whole number from 10 to 2000 GB | See "Disk size" |
| `max_runners` is a whole number from 1 to 100 | A tier that may run no runner serves nothing. 100 is far above what the quota allows (see "Quota") and keeps a typo from becoming a bill |
| `machine_type`, `boot_disk_gb` and `max_runners`, optionally `instance_template`, and no others | A misspelt field must not become a default. `null` for `instance_template` is the same as leaving it out, because that is how `jsonencode` writes an unset optional attribute |
| `instance_template`, if present, is `projects/<project>/global/instanceTemplates/<name>`, with lowercase letters, digits and `-` | It goes into the Batch request. Only this one spelling, so a bare name, which Batch would look up as a global template and then a regional one, cannot mean a different template than the one meant. Only the form is checked: Batch says whether the template exists and is in the job's project |
| No `RUNNER_IMPLICIT_LABELS` entry is a tier label | A label every runner holds would be a second tier label on every job that asks for it |

With an `instance_template` the template supplies the machine, disk, image, network and network tier. `machine_type` and
`boot_disk_gb` stay required and validated, but the Batch job does not send them ([Instance templates](../architecture/instance-templates.md)).

## Which jobs wake a tier

A `queued` or `completed` webhook reconciles a tier only if its job's labels contain exactly one tier label, compared without
regard to case, and every other label is `self-hosted` or one of `RUNNER_IMPLICIT_LABELS`. The same tier named twice counts once.
Anything else is ignored, and the `ignored workflow_job` log line gives the reason.

| Job's labels | Result |
|---|---|
| `[self-hosted, gcp-large]`, `[gcp-large]`, `[Self-Hosted, GCP-LARGE]` | Reconciles `gcp-large` |
| `[self-hosted]` | Ignored, `labels do not match`: it names no tier, so it is another self-hosted runner's job |
| `[self-hosted, gcp-large, gpu]` | Ignored, `labels do not match`: no runner of ours holds `gpu` |
| `[self-hosted, gcp-small, gcp-large]` | Ignored, `more than one tier label`: no runner holds both labels, so the job would stay queued however many runners were started |

The webhook only decides when a tier is reconciled. Which jobs count for a tier is GitHub's decision: the jobs it assigns to the
tier's scale set. A job the controller ignores but GitHub assigns to a scale set is still counted, and the next scheduled run
starts its runner. GitHub assigns a scale set no job that asks for `self-hosted`, so of the jobs above only `[gcp-large]` gets a
runner; `[self-hosted, gcp-large]` wakes the tier but waits for ever (Scale sets (gcp-runner-controller, `docs/architecture/scale-sets.md`)).

`RUNNER_IMPLICIT_LABELS` is empty by default because the labels GitHub adds on its own have not been confirmed for these runners.
If a registered runner of ours shows, say, `Linux` and `X64`, set `RUNNER_IMPLICIT_LABELS=linux,x64` so that webhooks of jobs
asking for `[self-hosted, gcp-large, linux]` wake the tier; until then they are ignored.

## Disk size

A VM cannot boot from a disk smaller than its image, and an image takes the size of the disk it was built on, so the build disk in
`image/action.yml` (`build-disk-gb`, 20 GB) is the least any tier can have with the baked image. About 6.4 GB of the disk is the image
and the rest is the job's. The controller cannot know the image's size, so its own floor is 10 GB, the disk of the stock Ubuntu
image, which is the least Compute Engine creates from the fallback image. A precondition in `instance-templates.tf` holds
every tier of a unit that boots the baked image to `image_disk_gb`, which a test keeps equal to the build disk, so raise the tiers'
disks before raising the build disk
(Image rebuilds (gcp-github-runners, `docs/operations/image-rebuilds.md`)).

## Quota

Two quotas bound the runners at once, whatever their tiers:

- **External addresses.** Each runner VM has an external IPv4 address, and europe-west10 allows 4 in use (`IN_USE_ADDRESSES`), so
  at most four VMs run there at once.
- **vCPUs.** The project allows 12 vCPUs across all regions (`CPUS_ALL_REGIONS`). `PREEMPTIBLE_CPUS` is 0, so Spot VMs draw on the
  regular quota. The region's own `CPUS` (32) is higher and does not bind, and the E2 runners count against `CPUS`, not against the
  region's `E2_CPUS`.

The quotas are the project's, so the deployment units of one project share them: a job of one unit can make another's wait in
Batch ([Deployment units](../architecture/deployment-units.md#what-units-of-one-project-share)). The image build VM takes one address and 2 vCPUs while it runs. The concurrent jobs the quotas allow depend on the mix:

| Tier | vCPUs counted | Most at once, alone | `max_runners` |
|---|---|---|---|
| `gcp-small` | 2 | 4, by addresses | 4 |
| `gcp-medium` | 2 | 4, by addresses | 4 |
| `gcp-large` | 4 | 3, by vCPUs | 2 |
| `gcp-xlarge` | 8 | 1, by vCPUs | 1 |

Each tier alone fits the quotas at its `max_runners`; tiers at their maxima together do not. While a `gcp-xlarge` job runs, 4 vCPUs
are left: two `gcp-small` or `gcp-medium` jobs, or one `gcp-large`. A job that cannot get quota waits in Batch instead of failing.
The shared-core `e2-medium` exposes 2 vCPUs and counts 2. A bigger tier costs more for every job that asks for it. The `gh-tier`
label is on each VM and disk, so Cloud Billing can group the bill by tier (Costs (gcp-github-runners, `docs/operations/costs.md`)).
