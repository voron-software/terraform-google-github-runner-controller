# Deployment units

A deployment unit is one installation of the runners for one GitHub organisation, in a Google Cloud project of its own: a
controller on Cloud Run, its sweep, its secrets, its service accounts, a firewall rule, one instance template per tier and the
runner image family `gh-runner`. This repository is the OpenTofu module that creates one unit, and the composite action that builds
its image. The controller itself, and how it works, is in the github-actions-runner-controller repository
(`docs/architecture/overview.md` there).

## What a unit needs

- A project, created outside the module, with the APIs, the network and a deployer that holds the roles in
  [Deployer requirements](../reference/deployer-requirements.md). The module creates no project and enables no API.
- A GitHub App installed on the organisation, a runner group, and the two secret versions a person adds after the first apply.
- A pinned controller image (`controller_image`), from a registry the project can pull from.

A project holds one unit. Whoever creates the project also gives the unit's installation its state and its deploy identity; a new
unit is a new project and a new installation, and the module is the same.

## Names

The module's names are fixed: the service accounts `controller-runtime`, `runner` and `controller-sweep`, the service
`controller`, the scheduler job `sweep-idle-runners`, the secrets `github-app-private-key` and `github-webhook-secret`, the firewall
rule `gh-runner-deny-ingress`, the instance templates `gh-tier-<label>-…`, the image family `gh-runner` and the build VM
`gh-image-…`. The last two are inside the names cloud-iac's `vmimages` condition admits.

A second unit in the same project would collide on every name, and its controller would count and delete the first unit's runners,
because a controller treats every runner job of its project and Batch location as its own.

## Why one unit per project

A project boundary is what keeps two organisations' units apart: quotas, IAM, the controller's project-wide `actAs`
([Security model](security-model.md#the-controller-can-act-as-any-service-account)) and the deployer are all per project. Sharing a
project would need a unit prefix on every name and a unit label on every Batch job, and a project per unit needs neither.

## Images

Each unit builds its own image with `image/action.yml`, into its own project's family, and its templates boot that family. No unit
reads another's image, so a unit needs no image grant, and a unit's image can be rebuilt or rolled back without touching the others
([Runner image](runner-image.md)).
