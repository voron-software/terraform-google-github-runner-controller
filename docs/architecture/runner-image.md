# Runner image

Each deployment unit builds the image family `gh-runner` in its own project, that
already holds Docker, the build toolchains and the pinned runner. The composite action `image/action.yml` builds it; the unit's
installation runs the action on a schedule, weekly for ours. The instance templates boot the family when `boot_baked_image` is true
([Instance templates](instance-templates.md)). No unit reads another's image, so no unit needs an image grant across projects.
The stock Ubuntu 24.04 family is the fallback: with `boot_baked_image` false, the VM script `runner.sh` installs what it finds missing, so jobs still run, without the Rust, Node and .NET
toolchains.

## Why bake an image

Rust repositories run on these runners, and the stock image has no C compiler, so `cargo` cannot link. Installing a compiler,
linkers, Rust, Node and .NET at boot on every job would add minutes to each one and fetch the same files from a dozen hosts
thousands of times. They are installed once, into an image. A job on the baked image also starts a minute sooner than on the stock
one, because `runner.sh` only starts the runner.

## What is in the image

| Layer | Contents | Why |
|---|---|---|
| OS packages | `build-essential`, `pkg-config`, `cmake`, `clang`, `lld`, `mold`, `libssl-dev`, `protobuf-compiler`, `postgresql-client`, `git`, `jq`, `unzip`, `zip`, `shellcheck` | A C toolchain and linkers for `cargo`, headers for crates that build against OpenSSL and protobuf, a Postgres client for integration tests, the tools setup actions shell out to, and the linter CI runs on shell scripts |
| GitHub CLI | `gh`, from GitHub's apt repository | GitHub-hosted runners have it and workflows call it (`gh release`, `gh api`); `taiki-e/install-action` has no manifest for it |
| Docker | Engine, CLI, containerd, Buildx, Compose, from Docker's apt repository | `docker build` and `container:` jobs |
| Rust, for the `runner` account | rustup with the minimal profile and `stable`; `rustfmt`, `clippy`, `rust-src`, `rust-analyzer`, `llvm-tools-preview`; target `wasm32-unknown-unknown`; `cargo-binstall`, and through it `cargo-llvm-cov`, `cargo-nextest`, `cargo-deny` and `trunk` 0.21.14 | What the organisation's workflows install with `dtolnay/rust-toolchain` and `taiki-e/install-action`, which still work and find these in place. `trunk` is pinned because every repository pins it |
| Node.js | The current 26.x from NodeSource, pinned by major | Frontend builds and the tools that run on Node |
| .NET | `dotnet-sdk-10.0` from Ubuntu's own feed | Microsoft's package repository has no .NET packages for Ubuntu 24.04, and Ubuntu's feed has 10.0 |
| Actions runner | The pinned release, extracted and with its dependencies installed | Saves the download and extraction on every job |
| The `runner` account | The account jobs run as, in the `docker` group and with passwordless `sudo` | As on GitHub-hosted runners, because workflows rely on both. The VM is single-use, so neither widens anything |
| Open-file limit | 65536, soft and hard, for every service, every container and the `runner` account | As on GitHub-hosted runners. Ubuntu's soft limit of 1024 makes a job that holds thousands of files open, such as a storage server in a container, fail with `too many open files` |
| Background apt | Off: `apt-daily`, `apt-daily-upgrade` and `unattended-upgrades` are masked | A job that runs `sudo apt-get install` must not wait for a background run to release the dpkg lock, or share its CPU. A VM runs one job, so there is nothing for unattended upgrades to protect, and the weekly rebuild keeps the packages current |
| Package lists | None: removed when the image is made | A job runs `sudo apt-get update` before it installs a package |
| SSH server | Masked, socket included | Nothing should accept a connection on a runner ([Security model](security-model.md#no-inbound-access-in-two-layers)) |

**Playwright is not in it.** Its browsers and system libraries are large and change faster than a weekly image. Workflows that
need them run Playwright inside the official `mcr.microsoft.com/playwright` container with `--network host`, which brings its own.

## How it is built

The action is run by the unit's installation, as the unit's deployer, after the caller has authenticated to Google Cloud. It is a
composite action and not a reusable workflow, because GitHub hands an action's files to the runner with the access this private
repository grants to the organisation's workflows, so the caller needs no token to read `build.sh`. The caller's job runs on
`ubuntu-latest`: it cannot run on the runners it builds the image for, because a broken or missing image would leave no runner to
repair it. The action creates a plain Ubuntu 24.04 VM, `gh-image-<unit>-<run id>-<attempt>`, whose startup script is `image/build.sh`, waits up to 40 minutes for the VM
to stop, reads its serial console and creates the image from its disk only if the script reported success. Then it deletes the VM,
the images of the family built on a disk of another size, and all but the newest three of the rest.

The VM is created with no service account and no scopes, on the default network with an external IP and the tag `gh-image`, which
the deny-all-ingress firewall rule covers (`firewall.tf`).

The build script ends by printing one line, `gh-image: build succeeded`, and stops the VM from an `EXIT` trap whether it
succeeded or not. The serial console is the VM's only log, because it has no identity to write to Cloud Logging. The action
looks for that line, and a test checks that the script and the action agree.

## Who may do what

| Identity | May | May not |
|---|---|---|
| The unit's deployer, `github-deploy` for ours, in the installation's image workflow (environment `prd`, so `main` only) | Create and delete instances and disks named `gh-image-*` and images named `gh-runner-*`, read the build VM's serial output, and do the project-level reads gcloud needs. cloud-iac's `vmimages` capability grants `roles/compute.instanceAdmin.v1` under an IAM condition that says exactly this. The condition is gated by resource type: the name restriction applies to instances, disks and images, and its clause for every other type admits the rest, so `compute.subnetworks.use` and `useExternalIp` on the default subnet, which creating the VM needs, are allowed | Touch the `gh-runner-*` VMs that Batch creates, or any other instance, disk or image |
| The build VM | Nothing: no service account, no scopes | Reach any Google API |
| `controller-runtime` and `runner` | The controller names the image through the instance template; the runner account holds only the two Batch roles | |

Keep the names `gh-image-*` and `gh-runner-*`, or our deployer loses its rights. Nothing in the module changes who may do what. The
image holds no credential: the build script takes no secret, and the runner it extracts is never configured, so no JIT config or
token can be in it.

## One source for the runner version

The runner version and digest are pinned in `image/runner-version.env`, which is the source of truth for the image. The action
reads it and passes the two values to the build VM as instance metadata, so the build script contains neither. The VM script
`runner.sh` is github-actions-runner-controller's: the controller embeds it and it runs on a bare VM, so it keeps its own pair as constants.
Renovate bumps the two repositories' pins in separate pull requests, and nothing compares them across repositories, so for a while
they can differ; the stamp below makes that safe.

The build script writes the version it extracted to `/etc/gh-runner-image/runner-version`, and the VM script uses the extracted
runner only when that stamp equals its own pin. An image built before a bump is therefore never run with the old runner: the
script downloads the pinned one for the jobs that start before the next image is ready.

## Rebuild, retention and failure

The family always resolves to its newest image, and an image is created only after the build is verified, so a failed build leaves
the previous image in use and runners keep working. Three images are kept so that a bad one can be deleted, which makes the family
fall back to the one before it. Images built on another disk size are deleted, because a boot disk cannot be smaller than its image
and the family resolves to its newest one. If the image itself is the problem, setting `boot_baked_image` to false returns to the stock
image on the next apply. Before the first build succeeds the family does not exist, so `boot_baked_image` stays false until then. The
procedures are in Image rebuilds (gcp-github-runners, `docs/operations/image-rebuilds.md`).

## Limits and risks

- **The image is trusted code.** Whatever is in it runs in every job as root-equivalent, and it is rebuilt from installers that run
  as root or as `runner` on the build VM: rustup, cargo-binstall and the prebuilt tools it fetches, NodeSource's and Docker's
  repositories, and apt. None is pinned except `trunk`, `node` by major and the runner, and no key is pinned by fingerprint. A
  compromised upstream during a build would persist for a week of jobs and not one VM. The build VM has no credentials, no inbound
  access and runs only on `main`, so the exposure is the image's contents, which is the exposure of boot-time installs for longer.
  Changes to `image/` deserve the review `runner.sh` gets.
- **The toolchains are up to a week old.** `stable` Rust, Docker, Node's patch level and the OS packages are at the versions of the last build. A
  job that pins another toolchain installs it, as on a hosted runner, and `dtolnay/rust-toolchain` updates `stable` at job time.
- **The build shares the quotas with the jobs**, of every unit in the project. The build VM is an `e2-standard-2` with an external address, and takes one of
  europe-west10's 4 in-use addresses and 2 of the project's 12 vCPUs while it runs ([Tiers](../reference/tiers.md#quota)). The
  build is bound by downloads and takes a few minutes. While it runs at most three jobs run at once, and a build started while four
  jobs are running fails to create its VM and has to be re-run.
- **Part of the runner's boot disk is the image**, about 6.4 GB. The disk the image is built on is the smallest boot disk a runner
  can have ([Tiers](../reference/tiers.md#disk-size)).
- **Cloud Batch and custom images.** Batch's documentation says that custom images "can be used with Batch but might not be
  supported", recommends building on a public image that Batch supports, and says that for an image that is neither a Batch image
  nor a custom image based on a Batch image, "Batch installs required packages on the job's VMs after they start"
  (<https://docs.cloud.google.com/batch/docs/vm-os-environment-overview>). Its Batch images are Debian, Container-Optimized OS and
  HPC Rocky Linux, so Ubuntu is not one, and this image is in the same position as the stock Ubuntu family: Batch installs its own
  packages on top. The first job that boots the image (the `Smoke Test` workflow) shows whether Batch accepts it. The way back is to
  set `boot_baked_image` to false.
- **Two scripts install Docker**, `runner.sh` for the fallback and `build.sh` for the image, in two repositories. The function
  `install_docker` should be the same text in both; nothing compares them since the split, so change both together.

## The contract with runner.sh

github-actions-runner-controller's `runner.sh` runs on this image and reads it at fixed paths: the runner in `/home/runner/actions-runner`, the
workspace root `/home/runner/work`, and the version stamp `/etc/gh-runner-image/runner-version`. `checks/tests/image.rs` holds
`build.sh` to them, and the controller repository holds `runner.sh` to the same literals, so a change on one side fails a test until
the other side's test is changed with it.

## Why not the alternatives

- **Install at boot.** It costs minutes per job and repeats every download.
- **Build the image on the runners themselves.** It is circular: a broken image would leave nothing to build the fix.
- **A tool such as Packer.** It needs a service account for the build VM and wider IAM than the condition above allows.
- **Put the toolchain in a container image.** Every repository would have to opt in, and actions that run on the host would still
  lack a compiler.
