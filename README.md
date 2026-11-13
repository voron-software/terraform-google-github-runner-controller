# gcp-runner-unit

An OpenTofu module that deploys one deployment unit of ephemeral GitHub Actions runners on Google Cloud, and the composite action
that builds the unit's runner image.

## Problem

A GitHub organisation that wants Spot-VM runners from the gcp-runner-controller needs the controller on Cloud Run, its sweep, its
accounts and secrets, a template per tier and a baked image, all named so that several organisations can share one project. The
module creates all of that from one call, and adding an organisation is one more call with another `name`.

## Quickstart

```hcl
module "unit" {
  source = "git::ssh://git@github.com/voron-software/gcp-runner-unit.git?ref=v0.1.0"

  name                       = "acme"
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

Build the unit's image from a workflow that has authenticated as the unit's deployer, then set `boot_baked_image = true`:

```yaml
- uses: voron-software/gcp-runner-unit/image@v0.1.0
  with:
    unit: acme
    project-id: my-runners
    zone: europe-west10-b
```

What the project and the deployer need first is in [Deployer requirements](docs/reference/deployer-requirements.md). The rest is
in the [documentation index](docs/README.md).
