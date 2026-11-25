# terraform-google-github-runner-controller

An OpenTofu module that deploys one deployment unit of ephemeral GitHub Actions runners on Google Cloud, and the composite action
that builds the unit's runner image.

## Problem

A GitHub organisation that wants Spot-VM runners on Google Cloud needs a controller on Cloud Run, its sweep, its accounts and
secrets, a template per tier and a baked image, in a project of its own. The module creates all of that in an existing project from
one call; another organisation is another project and another call. The controller is a container image that the module deploys, and
is not part of this repository.

## Quickstart

```hcl
module "unit" {
  source = "git::https://github.com/voron-software/terraform-google-github-runner-controller.git?ref=v0.2.0"

  project_id                 = "my-runners"
  location                   = "europe-west3"
  batch_location             = "europe-west10"
  github_org                 = "acme"
  github_app_id              = 123456
  github_app_installation_id = 7890123
  github_runner_group_id     = 3
  controller_image           = "europe-west3-docker.pkg.dev/my-runners/cloudrun/controller:v0.1.0"
  runner_tiers = {
    gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 2 }
  }
}
```

Pin `ref` to a release tag; a tag is never moved. Target state: the module is also published on the Terraform Registry, as
`voron-software/github-runner-controller/google`, and a caller can then use that source with `version = "0.2.0"`. The image action
below is always fetched from GitHub.

Build the unit's image from a workflow that has authenticated as the unit's deployer, on a GitHub-hosted runner, then set
`boot_baked_image = true`:

```yaml
- uses: voron-software/terraform-google-github-runner-controller/image@v0.2.0
  with:
    project-id: my-runners
    zone: europe-west10-b
```

Each runner VM takes an external IPv4 address and its vCPUs from the project's Compute Engine quota, so a new project's quota may
need raising before the unit can run more than a few jobs at once ([Quota](docs/reference/tiers.md#quota)). What the project and the
deployer need first is in [Deployer requirements](docs/reference/deployer-requirements.md), and the steps from an empty project to the
first job are in [Installing a unit](docs/guides/installing-a-unit.md). The rest is in the [documentation index](docs/README.md).
