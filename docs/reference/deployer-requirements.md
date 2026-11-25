# Deployer requirements

What a project needs, and what its deployer must hold and be allowed to grant, before a deployment unit is applied in it. The
module enables no API and holds no project role beyond the eight it grants its own accounts, so everything below exists before the
apply. The lists are in
[`metadata.yaml`](../../metadata.yaml), Google's blueprint metadata format, which Google Cloud Marketplace reads for a
Terraform product; this page says why each entry is there. A test, `checks/tests/deployer_requirements.rs`, fails when
the file and the module's resource types disagree, and when an entry of the file is missing here.

The deployer is the identity that runs the apply, and the one the image build workflow authenticates as: any account or service
account you choose. `roles/owner` holds every entry. `roles/editor` does not, because it cannot write the project's IAM policy.

## APIs to enable

`spec.requirements.services`. Enable all of them once, before the first apply: the module enables none.

| API | Needed by | When |
|---|---|---|
| `run.googleapis.com` | `google_cloud_run_v2_service`, the controller | Apply and runtime |
| `cloudscheduler.googleapis.com` | `google_cloud_scheduler_job`, the sweep | Apply and runtime |
| `cloudtasks.googleapis.com` | `google_cloud_tasks_queue`, webhook mode's queues (`tasks.tf`); the controller adds, lists and deletes their tasks | Apply and runtime |
| `secretmanager.googleapis.com` | the two secrets, their accessor bindings and the read of each one's newest version; Cloud Run reads the secrets at start | Apply and runtime |
| `iam.googleapis.com` | the three service accounts | Apply |
| `cloudresourcemanager.googleapis.com` | `google_project_iam_member` and the `google_project` data source, which Resource Manager serves | Apply |
| `compute.googleapis.com` | the firewall rule and the instance templates; Batch creates the VMs through it | Apply and runtime |
| `batch.googleapis.com` | The controller submits one Batch job per runner, and Batch creates the VMs | Runtime only |
| `logging.googleapis.com` | The `runner` account writes each task's logs, and Batch reads them back | Runtime only |

Batch's own prerequisites are Batch, Compute Engine and Cloud Logging
([Get started with Batch](https://cloud.google.com/batch/docs/get-started)). A runtime-only API fails no apply, and a job fails
for want of it, so a customer enables it with the rest.

## Roles the deployer holds

`spec.requirements.roles`, at the project. Each is the narrowest predefined role with the permissions the module's resources need.
Several hold more: the third column says what, and the last what a custom role or a condition would
grant instead. A customer who trusts the deployer with the broader role needs nothing narrower.

| Role | Needed for | Holds beyond that | Narrower |
|---|---|---|---|
| `roles/run.admin` | Create, update and delete the controller service, and turn its invoker check off, which needs `run.services.setIamPolicy` ([Allowing public access](https://cloud.google.com/run/docs/authenticating/public)); `roles/run.developer` lacks it | Every Cloud Run service and job in the project | None that is predefined |
| `roles/cloudscheduler.admin` | Create, update and delete the sweep job | Every scheduler job in the project | None: it is the least that creates a job |
| `roles/cloudtasks.queueAdmin` | Create, update, pause, resume and delete the queues | Every queue in the project, and purging them | A custom role of `cloudtasks.queues.{create,delete,get,list,pause,resume,update}` |
| `roles/secretmanager.admin` | Create the two secrets, write their IAM policy and read the metadata of their newest version (`secretmanager.versions.get`), which the service pins | Read every secret value (`secretmanager.versions.access`) and add or destroy versions | A custom role of the `secretmanager.secrets.*` permissions and `secretmanager.versions.get` |
| `roles/iam.serviceAccountAdmin` | Create, update and delete the three accounts | Write any account's IAM policy, which includes granting itself impersonation of it | A custom role of `iam.serviceAccounts.{create,delete,get,list,update}` |
| `roles/iam.serviceAccountUser` | `actAs` on `controller-runtime` (the Cloud Run service), `runner` (the templates) and `controller-sweep` (the scheduler job's token) | `actAs` on every account in the project, including ones the module does not own | The same role on the three accounts alone, which needs the right to write their IAM policy and so cannot be the deployer's |
| `roles/compute.securityAdmin` | Create, update and delete the firewall rule | Every firewall policy and security policy | A custom role of `compute.firewalls.*` and `compute.networks.updatePolicy` |
| `roles/compute.instanceAdmin.v1` | Create, read and delete the global instance templates, and, in the image build workflow, create and delete the build VM, its disk and the images ([Runner image](../architecture/runner-image.md#who-may-do-what)) | Create, edit, set the metadata of and read the serial output of every VM, and the runner VMs run a job's code as root | A custom role of `compute.instanceTemplates.{create,delete,get,list}` for the apply, and for the image build the same role under an IAM condition on the names the build uses |
| `roles/resourcemanager.projectIamAdmin` | Write the project's IAM policy, for the eight grants below | Grant any role to any principal, itself included, which is as much as owner | A custom role of `resourcemanager.projects.{getIamPolicy,setIamPolicy}`, bound with an IAM condition that admits the eight roles below only |

`roles/compute.instanceAdmin.v1` is the widest, and the one a customer should replace first. The module reads the project
(`resourcemanager.projects.get`), which every role in the table includes.

## What the project has

The module creates no network. The firewall rule is on the network `default` (`firewall.tf`), and every instance template names
that network and a subnetwork `default` in `batch_location` (`instance-templates.tf`), so the project needs a VPC network
`default` with a subnet `default` in the region of the runner VMs before the apply. A project created with the organisation policy
`constraints/compute.skipDefaultNetworkCreation` enforced has none ([Organization policy
constraints](https://docs.cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints)), and the apply fails
at the firewall rule and the templates. An auto-mode network makes a subnet named `default` in every region:

```bash
gcloud compute networks create default --subnet-mode=auto --project <project>
```

No variable names another network or subnetwork.

## Roles the module grants

The deployer must be allowed to grant these, and no others: the annotation `grantable-project-roles` in `metadata.yaml`
lists them, and the test requires it to equal the set of roles the module grants with `google_project_iam_member`. A condition on
the deployer's grant of `roles/resourcemanager.projectIamAdmin`, or on its custom role, of the form
`api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([...])` admits exactly these
([Set limits on granting roles](https://cloud.google.com/iam/docs/setting-limits-on-granting-roles)). The `secretAccessor` role on
each secret is a secret-level binding, not a project role, and `roles/secretmanager.admin` covers it.

| Role | Granted to | Why |
|---|---|---|
| `roles/batch.jobsEditor` | `controller-runtime` | Submit and delete the Batch jobs |
| `roles/iam.serviceAccountUser` | `controller-runtime` | Attach the `runner` account to each job |
| `roles/cloudtasks.enqueuer` | `controller-runtime` | Webhook mode: add a waiting job's record and a tier's wake-up. A wake-up's ID token is signed as `controller-sweep`, which the controller can act as through `roles/iam.serviceAccountUser` |
| `roles/cloudtasks.taskDeleter` | `controller-runtime` | Webhook mode: drop a waiting job's record |
| `roles/cloudtasks.viewer` | `controller-runtime` | Webhook mode: list a tier's records, in the basic view that holds no body |
| `roles/compute.viewer` | `controller-runtime` | Batch requires a job's submitter to read the instance template it uses ([Define job resources using a VM template](https://cloud.google.com/batch/docs/create-run-job-vm-template)) |
| `roles/batch.agentReporter` | `runner` | Batch requires it of every task account, to report the task's state |
| `roles/logging.logWriter` | `runner` | Batch requires it to write the task's logs |

## When the apply goes through something else

- **Infrastructure Manager.** If the module is applied by Infrastructure Manager and not by an account that runs `tofu` itself, the
  project also needs `config.googleapis.com` enabled ([Quickstart](https://docs.cloud.google.com/infrastructure-manager/docs/quickstart),
  `gcloud services enable config.googleapis.com`), and the service account the deployment runs as needs `roles/config.agent` besides
  the roles above ([Configure a service account](https://docs.cloud.google.com/infrastructure-manager/docs/configure-service-account)).
  Neither is in `metadata.yaml`, which lists what the module itself needs.
- **An organisation policy on the invoker check.** The service turns Cloud Run's invoker check off (`invoker_iam_disabled` in
  `cloudrun.tf`), because GitHub cannot present Google credentials. The managed constraint
  `constraints/run.managed.requireInvokerIam`, which is not enforced by default, restricts the ability to disable that check
  ([Allowing public access](https://docs.cloud.google.com/run/docs/authenticating/public)). Where it is enforced the apply fails at the
  service, and the organisation has to exempt the project.

## What the registry owner grants

A unit builds its own runner image in its own project ([Runner image](../architecture/runner-image.md)), so it reads no image of
anyone else's. It reads one thing across projects when the controller image is not in the unit's project: the controller image,
from the Artifact Registry repository that holds it. The grants are on the registry owner's side, and the module does not make them.
A unit whose controller image is in its own project needs neither.

| Principal | Resource in the registry's project | Role | Why |
|---|---|---|---|
| The Cloud Run service agent, `service-<project number>@serverless-robot-prod.iam.gserviceaccount.com` | The Artifact Registry repository of the controller image | `roles/artifactregistry.reader` | Pull the image ([Deploying container images](https://cloud.google.com/run/docs/deploying)) |
| The deployer | The same repository | `roles/artifactregistry.reader` | Cloud Run lists it among the roles of whoever deploys an image from another project |

## Changing the module

A new resource type in the module needs a row in `NEEDS` in the test, with the API it calls and the roles that manage it. The same
APIs and roles go in `spec.requirements` of `metadata.yaml` and in the tables above, or the test names which is missing. An
API the controller uses at run time and no resource calls has a row in `RUNTIME_ONLY` with its reason. A project role the module
starts to grant goes in `grantable-project-roles`, and a deployer limited to the eight roles above has to be widened first
([AGENTS.md](../../AGENTS.md)).

The file holds `requirements` and the identity of the module only. `spec.interfaces` (variables and outputs), `spec.content`, the
actuation tool and the rest of `spec.info` come from the toolkit's generator, `cft blueprint metadata -p .`, which needs a
`README.md` and takes the title from its first heading. Run on this file with no `test/setup/iam.tf` and `test/setup/main.tf`
beside it, it keeps `requirements` and the annotations as they are, and it rewrites the file without its comments. Validate with
`cft blueprint metadata -p . --validate`, which checks the file against Google's schema
([`gcp-blueprint-metadata.json`](https://github.com/GoogleCloudPlatform/cloud-foundation-toolkit/blob/master/cli/bpmetadata/schema/gcp-blueprint-metadata.json),
`apiVersion: blueprints.cloud.google.com/v1alpha1`). That check is not part of the test, which needs no Go tool.
