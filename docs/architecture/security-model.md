# Security model

What a job, the controller and a person can reach, and what limits each. The identities and their roles are listed in the
overview (gcp-runner-controller, `docs/architecture/overview.md`).

## A job is trusted code

Anyone who can push a workflow to a repository in the runner group runs commands on a VM with outbound internet access,
passwordless `sudo` and the root-equivalent `docker` group. Through `sudo` a job can also read the runner's own environment, which
holds the JIT config. That config is good for one runner only, and the VM is deleted after the job, so nothing the job does
outlives it. Restrict who can write to those repositories accordingly.

## Private repositories only

The runner group lists specific private repositories and refuses public ones. A pull request from a fork of a public repository
could otherwise run its own code on these machines.

## The runner account is nearly empty

A job can ask the metadata server for the VM's service account token. The `runner` account holds `roles/batch.agentReporter` and
`roles/logging.logWriter`, which Batch requires of every task account, so the token can write log entries and report task state
and open nothing else: no VM, no secret, no data. Any further role would go to every workflow in the runner group, so a test in
`tests/` fails if the account gains one.

## No inbound access, in two layers

A firewall rule per unit (`firewall.tf`) denies all ingress to the runner VMs and the image-build VM at priority 100, above the default
network's allow rules, and the image masks the SSH server, socket included. There is no route to log in to a runner; debug
through the job's logs in Cloud Logging (Troubleshooting (gcp-github-runners, `docs/operations/troubleshooting.md`)).

## The controller authenticates every caller

Cloud Run's invoker check is off, because GitHub cannot present Google credentials. The controller verifies each webhook's
`X-Hub-Signature-256` and ignores deliveries from any installation but its own. `/sweep` accepts only a Google-signed ID token for
the controller's URL issued to the `controller-sweep` account, which Cloud Scheduler sends. The checks are in
Endpoints (gcp-runner-controller, `docs/reference/endpoints.md`).

## The controller can act as any service account

The controller's `roles/iam.serviceAccountUser` is project-wide and unconditional. IAM conditions cannot target service accounts,
and a conditional binding would break every job submit. The cost is that the controller can act as any service account in the
project, `github-deploy` included, so a compromised controller could submit a Batch job that runs as the deploy identity. A
compromised controller already holds `roles/batch.jobsEditor` and so can run code on VMs, which limits what the wider grant adds.

Units of one project make this wider: a unit's controller can act as another unit's `runner` account, and submit Batch jobs in
their project. Every unit of a project is the same publisher's, and each `runner` account is nearly empty, so this lets one unit's
controller do nothing the other's could not; a unit whose GitHub organisation must not share that trust goes in its own project
([Deployment units](deployment-units.md#what-units-of-one-project-share)).

Target state: the unit binds `actAs` on its own `runner` account alone. `github-deploy` cannot write service account IAM policies,
so the module cannot do it for our installation.

## Secrets are write-only for people

The App private key and the webhook secret live in Secret Manager. A secret operator can add and retire versions but not read
them, and `github-deploy` cannot read them either. Only `controller-runtime` holds `secretAccessor`, on those two secrets.

## A unit in another project reads one thing of the publisher's

A unit builds its own runner image, so the only thing it reads across projects is the controller image, when it is not in the
publisher's project: its Cloud Run service agent and its deployer need `roles/artifactregistry.reader` on that one repository
([Deployer requirements](../reference/deployer-requirements.md#what-the-publisher-grants)). It can pull the controller and cannot
push, tag or delete it. A job there runs with that project's accounts, so it reaches nothing of the publisher's.

## The image is trusted code

Whatever is in the runner image runs in every job. It is rebuilt weekly from third-party installers on a build VM with no
credentials and no inbound access, only from `main` (the `prd` environment), and it holds no secret and no runner registration.
A change to `image/` deserves the review `runner.sh` gets. The exposure is in
[Runner image](runner-image.md#limits-and-risks).

## Every VM is deleted

Deletion has two links and one backstop. Batch deletes the VM when the script exits. The reconcile, at least every five minutes,
deletes the Batch job of a runner that finished, removes idle runners GitHub has no job for, and deletes a job running past its
grace with no runner registered. The 6-hour maximum run duration ends a task that is still running. A VM whose runner never comes
online while its tier's count still asks for a runner can run for up to those 6 hours
(Batch jobs (gcp-runner-controller, `docs/architecture/batch-jobs.md`), Orphan VMs (gcp-github-runners, `docs/operations/reconciling-runners.md`)).
