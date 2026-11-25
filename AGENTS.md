# Agent notes

The OpenTofu module for one deployment unit of the GitHub runners, at the repository root, and `image/`, the composite action
that builds a unit's runner image. How it works is in the [documentation index](docs/README.md). The controller it deploys is a
separate, private codebase that reaches a unit only as a container image.

## Layout

| Path | Owns |
|---|---|
| `*.tf` | The module: one unit in an existing project, with fixed resource names |
| `metadata.yaml` | Blueprint metadata: the APIs and roles a deployer needs ([Deployer requirements](docs/reference/deployer-requirements.md)) |
| `tests/` | `tofu test` against a mock provider |
| `image/` | `action.yml`, `build.sh` (the build VM's startup script) and `runner-version.env`, the runner pin of the image |
| `checks/` | Rust tests of what `tofu test` cannot see: the deployer requirements, the image scripts, the module's placement |

## Checks

```bash
tofu init -backend=false
tofu fmt -check -recursive
tofu validate
tofu test
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
shellcheck image/build.sh
actionlint
```

## Rules

- A project holds one unit, so resource names are fixed literals; renaming one replaces it, secrets included
  ([Deployment units](docs/architecture/deployment-units.md)).
- The family `gh-runner` is written twice, in `instance-templates.tf` (`image_family`) and `image/action.yml`, and the build disk twice, in
  `instance-templates.tf` (`image_disk_gb`) and the action's `build-disk-gb` default. Change both sides; a test compares them.
- The module grants exactly the eight project roles in `metadata.yaml`'s `grantable-project-roles`, which a limited deployer is
  allowed to grant. A ninth role, a new resource type or a new API is a change to `metadata.yaml`,
  `checks/tests/deployer_requirements.rs` and [Deployer requirements](docs/reference/deployer-requirements.md) together, and an
  installation whose deployer is limited to the eight has to be widened before it applies the release.
- The tier, sweep-grace and poll-timeout bounds in `variables.tf` repeat the controller's. Change both repositories together.
- `runner_pending_warn_seconds` in `variables.tf` repeats the controller's bounds for `RUNNER_PENDING_WARN_SECONDS`. Change both
  repositories together.
- Grant the `runner` service account nothing beyond `roles/batch.agentReporter` and `roles/logging.logWriter`; a test fails if it
  gains a role ([Security model](docs/architecture/security-model.md)).
- Keep `name_prefix` and `create_before_destroy` on the instance templates, and Spot, the `STANDARD` network tier, the
  `github-runner` tag and the `runner` account in them; tests fail if any goes.
- Keep the names `gh-image-*` for build instances and disks and `gh-runner-*` for images: a deployer limited by name admits only
  those ([Runner image](docs/architecture/runner-image.md#who-may-do-what)).
- `build.sh` keeps the paths `runner.sh` reads ([Runner image](docs/architecture/runner-image.md#the-contract-with-runnersh)), prints
  its success line last and only on success, and never logs a secret.
- Never manage a secret version in OpenTofu: people add them, and the module only reads the newest version's number.
- This repository is public, and so is its history. Nothing of an installation goes into code, tests, docs or commit messages: no
  project id or number, service account address, internal hostname or name of a private repository. Examples use `acme-runners`,
  `acme-org` and `123456789012`.
- CI runs on GitHub-hosted runners only, on `pull_request` with a read-only token and no secrets. Never add a self-hosted label, a
  secret or `pull_request_target` to a workflow that a fork's pull request can start.
- Comments say why, not what.
- Release by tag only, and never move a tag; the version rules are in [Releases](docs/operations/releases.md).
