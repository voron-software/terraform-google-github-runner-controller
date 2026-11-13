# Deployment units

A deployment unit is one installation of the runners for one GitHub organisation: a controller on Cloud Run, its sweep, its
secrets, its service accounts, a firewall rule, one instance template per tier and its own runner image family. This repository is
the OpenTofu module that creates one unit, and the composite action that builds its image. The controller itself, and how
it works, is in the gcp-runner-controller repository (`docs/architecture/overview.md` there).

## What a unit needs

- A project with the APIs, the network and a deployer that holds the roles in
  [Deployer requirements](../reference/deployer-requirements.md). The module creates no project and enables no API.
- A GitHub App installed on the organisation, a runner group, and the two secret versions a person adds after the first apply.
- A pinned controller image (`controller_image`), from a registry the project can pull from.

A new unit in a project that already hosts units needs nothing new from the project or its deployer: another call of the module
with another `name`. For our own installation that is a change to gcp-github-runners alone, and none to cloud-iac.

## Names

Every resource the module creates is named with the prefix `<name>-`, so units of one project never share a name: the service
accounts `<name>-controller-runtime`, `<name>-runner` and `<name>-controller-sweep`, the service `<name>-controller`, the scheduler
job, the two secrets, the firewall rule and the instance templates `gh-tier-<name>-<label>-…`. The image family is
`gh-runner-<name>` and the build VM `gh-image-<name>-…`, which keeps both inside the names cloud-iac's `vmimages` condition admits.
A service account id is at most 30 characters, so `name` is at most 11.

The controller gets `DEPLOYMENT_UNIT=<name>`, labels every Batch job it creates with `gh-unit=<name>`, and lists only the jobs with
its own label. Without that, two units with a tier of the same label in one project and Batch region would count, and delete, each
other's runners.

### The legacy unit

One installation of ours keeps names without a prefix: `legacy_names = true` drops the prefix, sets no `DEPLOYMENT_UNIT`
and boots the family `gh-runner`. Its controller lists only jobs with no unit label. Renaming it would replace its secrets, which hold versions a person added and which `prevent_destroy` protects, and its
service accounts. At most one unit of a project may set it; the module cannot see its siblings, so the caller's root checks that.

## What units of one project share

- **Quotas.** External addresses and vCPUs are the project's and the region's, so a job of one unit can make another's wait in Batch
  ([Tiers](../reference/tiers.md#quota)).
- **`actAs`.** Each controller holds `roles/iam.serviceAccountUser` on the project, so it could submit a job as another unit's
  `runner` account ([Security model](security-model.md#the-controller-can-act-as-any-service-account)).
- **The deployer**, which applies every unit of the project.
- **The controller image's registry.** Units in the publisher's project read it without a grant.

A unit whose organisation must not share these goes in a project of its own. That needs the project, its APIs and its deployer
first, which for us is a cloud-iac change; the module is the same.

## Images

Each unit builds its own image with `image/action.yml`, into its own family in its own project, and its templates boot that
family. No unit reads another's image, so a unit in another project needs no image grant, and a unit's image can be rebuilt or
rolled back without touching the others ([Runner image](runner-image.md)).
