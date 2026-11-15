#!/usr/bin/env bash
# The startup script of the image-build VM (docs/architecture/runner-image.md). image/action.yml creates a plain Ubuntu 24.04 VM with this file as
# its startup-script, waits for the VM to stop, and turns its boot disk into the unit's image family that the runner VMs boot
# from. Google runs the script as root on the VM's first boot.
#
# The VM has no service account and no scopes, so nothing here can reach a Google API, and nothing here may need a secret. The only
# inputs are the instance attributes RUNNER_VERSION and RUNNER_SHA256, which the workflow copies from image/runner-version.env.
#
# The workflow tells success from failure by one line on the serial console, written as the last thing the script does. The VM
# stops either way (the EXIT trap below), so a failed build does not sit running until the workflow's timeout.
set -euo pipefail

# Stops the VM whether the build worked or not, so the workflow's wait ends as soon as the script does. The VM is not deleted here
# because the workflow still needs its disk for the image and its serial output for the verdict.
trap 'shutdown -h now' EXIT

export DEBIAN_FRONTEND=noninteractive
# Ubuntu's own first-boot apt jobs can hold the dpkg lock; wait for it instead of failing the build. Progress bars are off because
# the serial console is the only log this VM has, and it keeps only the last 1 MB.
apt_get() { apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Use-Pty=0 -q -y "$@"; }

# Background apt is switched off in the image, and first here so that it does not compete with this build either. A job that runs
# `sudo apt-get install` must not wait for a background run to release the dpkg lock, or share its CPU: runner VMs live for one job,
# so there is nothing for unattended upgrades to protect, and the weekly rebuild keeps the packages current. Masked, not just
# disabled, so that nothing can start the units again, and not purged, so that a metapackage which depends on the package is left
# alone. No `--now`: the units may not exist, and the build does not need them stopped, only the image.
systemctl mask apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service

# Nothing should ever accept a connection on a runner. No job needs to log in to its VM, and a firewall rule denies all ingress
# (firewall.tf), but a job's own code runs on the machine, so the SSH server is switched off here as the layer that holds if the
# rule is ever changed or bypassed. Both units are masked, because Ubuntu 24.04 starts ssh.service on demand from ssh.socket, and
# masking only the service would leave the socket listening. No `--now`, as above: the image needs the units off, not this VM.
systemctl mask ssh.service ssh.socket

# Every service, container and job gets the open-file limit of GitHub-hosted runners, 65536 soft and hard, because workflows are
# written against it and Ubuntu's soft limit of 1024 breaks them: kaon-db's RustFS container answered HTTP 500 "too many open files"
# to a 2400-file read-back that passes on a hosted runner. GitHub sets DefaultLimitNOFILE for systemd units, and so does this. A
# container inherits the limit of containerd and dockerd, so the default covers it as long as their unit files do not set
# LimitNOFILE themselves, which the checks below enforce. Written before Docker is installed, so that the daemons start under it
# and nothing needs a restart. `daemon-reload` makes systemd 255 (Ubuntu 24.04) read system.conf.d again.
nofile=65536
install -d /etc/systemd/system.conf.d
printf '%s\n' '[Manager]' "DefaultLimitNOFILE=$nofile:$nofile" > /etc/systemd/system.conf.d/nofile.conf
systemctl daemon-reload
# The default does not reach the runner: runner.sh starts it with `sudo -u runner`, so its limit would be whatever the Batch agent
# that runs that script has, which this image does not control. sudo opens a PAM session for the target user and applies this file
# to it, because Ubuntu 24.04's /etc/pam.d/sudo loads pam_limits itself, ahead of its common-session include. The `*` does not
# cover root, whose processes get the systemd default above.
printf '%s\n' "* soft nofile $nofile" "* hard nofile $nofile" > /etc/security/limits.d/runner.conf

metadata() {
  curl -fsSL --retry 5 -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

# The pin lives in image/runner-version.env and is never written here, so there are not two places to keep in step. The format checks keep a malformed attribute from reaching a download URL or the digest comparison.
RUNNER_VERSION="$(metadata RUNNER_VERSION)"
RUNNER_SHA256="$(metadata RUNNER_SHA256)"
[[ $RUNNER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "gh-image: RUNNER_VERSION attribute is missing or malformed" >&2; exit 1; }
[[ $RUNNER_SHA256 =~ ^[0-9a-f]{64}$ ]] || { echo "gh-image: RUNNER_SHA256 attribute is missing or malformed" >&2; exit 1; }

# Docker's documented apt setup for Ubuntu: https://docs.docker.com/engine/install/ubuntu/. Nothing is pinned, so each rebuild gets
# the current stable Engine. The same function is in github-actions-runner-controller's runner.sh, which installs Docker itself when it boots
# from the stock image instead of this one; change the two together (docs/architecture/runner-image.md, "Limits and risks").
install_docker() {
  apt_get update
  apt_get install ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 5 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_SOURCES
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_SOURCES
  apt_get update
  apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

echo "gh-image: installing Docker"
install_docker
docker info > /dev/null

# NodeSource's documented manual repository setup (https://github.com/nodesource/distributions/wiki/Repository-Manual-Installation).
# Pinned by major through the repository path, so a weekly rebuild takes Node's patch releases and never a new major. The key is
# kept armoured (.asc), which apt accepts in Signed-By, so gnupg is not needed to dearmor it.
node_major=26
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 5 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /etc/apt/keyrings/nodesource.asc
chmod a+r /etc/apt/keyrings/nodesource.asc
cat > /etc/apt/sources.list.d/nodesource.sources <<NODESOURCE
Types: deb
URIs: https://deb.nodesource.com/node_${node_major}.x/
Suites: nodistro
Components: main
Signed-By: /etc/apt/keyrings/nodesource.asc
NODESOURCE

# The GitHub CLI from GitHub's own apt repository (https://github.com/cli/cli/blob/trunk/docs/install_linux.md), because GitHub-hosted
# runners have `gh` and workflows call it (`gh release ...`), and taiki-e/install-action has no manifest for it. Ubuntu's own package
# is older, and apt takes the newer version from this repository. The repository publishes its keyring in binary form (.gpg), which
# apt accepts in Signed-By as it is. The file holds the repository's expired key as well as the one that signs it now, so it is
# fetched on every build and not copied into this repository. amd64 only, as the runner download below is.
curl -fsSL --retry 5 https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
cat > /etc/apt/sources.list.d/github-cli.sources <<GITHUB_CLI
Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/githubcli-archive-keyring.gpg
GITHUB_CLI

# What the organisation's Rust, Node and .NET workflows need and the stock image lacks: a C toolchain and linkers for cargo, TLS and
# protobuf headers for the crates that build against them, a Postgres client for the integration tests, and the archive tools the
# setup actions shell out to, and the two command-line tools that GitHub-hosted runners have and that workflows call directly: `gh`
# (from the repository above) and `shellcheck` (Ubuntu's package). dotnet-sdk-10.0 comes from Ubuntu's own feed: Microsoft's package repository no longer carries .NET
# for Ubuntu 24.04 (https://learn.microsoft.com/en-us/dotnet/core/install/linux-ubuntu-install).
#
# Playwright's browsers and their system libraries are deliberately not here. They are large, they change faster than a weekly
# image, and the workflows that need them run Playwright inside the official mcr.microsoft.com/playwright container with
# `--network host`, which brings its own.
echo "gh-image: installing the build toolchain"
apt_get update
apt_get install \
  build-essential pkg-config cmake clang lld mold libssl-dev protobuf-compiler \
  postgresql-client git jq unzip zip shellcheck gh \
  nodejs dotnet-sdk-10.0

# In the docker group so `docker build` and `container:` jobs work. That group is root-equivalent on a runner VM, which is
# acceptable only because the VM is single-use and its service account holds nothing beyond what Batch requires of it.
useradd --create-home --shell /bin/bash --groups docker runner
# Passwordless sudo, as on GitHub-hosted runners, because workflows rely on it (`sudo apt-get install ...`). It widens nothing:
# the VM is disposable and the docker group above is already root-equivalent.
printf '%s\n' 'runner ALL=(ALL) NOPASSWD:ALL' | install -m 0440 /dev/stdin /etc/sudoers.d/runner

# The Rust toolchain belongs to `runner`, the account jobs run as, so that `cargo` writes to its own home and rustup can update the
# toolchain in a job. `dtolnay/rust-toolchain` and `taiki-e/install-action` find these installed and only top them up.
echo "gh-image: installing the Rust toolchain"
sudo -H -u runner bash -euo pipefail <<'AS_RUNNER'
curl --proto '=https' --tlsv1.2 -sSf --retry 5 https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain stable
export PATH="$HOME/.cargo/bin:$PATH"
rustup component add rustfmt clippy rust-src rust-analyzer llvm-tools-preview
rustup target add wasm32-unknown-unknown

# cargo-binstall's documented direct download of its release binary, in place of piping its install script from the main branch.
# It fetches prebuilt binaries and falls back to compiling (--locked keeps that on the crates' lockfiles).
curl --proto '=https' --tlsv1.2 -sSfL --retry 5 \
  https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-x86_64-unknown-linux-musl.tgz \
  | tar -xz -C "$HOME/.cargo/bin"
# trunk is pinned because every repository pins one version and a newer trunk changes its output; `=` makes binstall read the
# version as exact. Renovate edits the version (.github/renovate.json5) and matches the text `trunk@=`, so keep that spelling. The
# other three follow their latest release, which is what the install actions they replace would fetch.
cargo binstall --no-confirm --locked cargo-llvm-cov cargo-nextest cargo-deny trunk@=0.21.14
AS_RUNNER
# No /etc/environment or /etc/profile.d entry is written for ~/.cargo/bin: a job's shell is not a login shell, and sudo replaces the
# PATH of the runner it starts with its own secure_path, so such an entry could not be relied on to reach a job. What does is the
# command in github-actions-runner-controller's runner.sh that starts the runner, which sets the PATH inside the sudo. rustup's edits to the
# runner's .profile and .bashrc cover a person who logs in to a VM made from this image to debug it.

# Installed here so that a VM does not download and unpack it on every job. The check is the one runner.sh makes, so a pin that
# does not match the download fails the build and not a job.
echo "gh-image: installing runner $RUNNER_VERSION"
runner_home=/home/runner/actions-runner
# Where jobs are checked out: the controller puts "../work" in the JIT config (relative to $runner_home), as on GitHub-hosted runners.
# The runner creates it if it is missing; it is made here so that the path is stated in one place and owned by `runner`.
runner_work=/home/runner/work
tarball="actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
install -d -o runner -g runner "$runner_home" "$runner_work"
curl -fsSL --retry 5 -o "/tmp/$tarball" "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$tarball"
echo "$RUNNER_SHA256  /tmp/$tarball" | sha256sum --check --quiet -
tar -xzf "/tmp/$tarball" -C "$runner_home"
rm "/tmp/$tarball"
chown -R runner:runner "$runner_home"
(cd "$runner_home" && ./bin/installdependencies.sh)
# runner.sh skips its own download only when this stamp names the version it pins, so an image that is behind a runner bump falls
# back to the full install instead of running an older runner.
install -d /etc/gh-runner-image
printf '%s\n' "$RUNNER_VERSION" > /etc/gh-runner-image/runner-version

# Every tool a workflow is told about, run once as the account that will use it. A tool that did not install, or a runner account
# that cannot reach Docker or find cargo, fails the build here and not in somebody's job. The output also lands in the serial log.
# The open-file limit is read back after the tools, and the loop at the end prints the state of the units that must stay off
# (background apt and the SSH server) and fails the build on any that is not masked.
echo "gh-image: checking the installed tools"
as_runner() { sudo -H -u runner env "PATH=/home/runner/.cargo/bin:$PATH" "$@"; }
cc --version | head -1
as_runner rustc --version
as_runner cargo --version
as_runner cargo llvm-cov --version
as_runner cargo nextest --version
as_runner cargo deny --version
as_runner trunk --version
as_runner rustup target list --installed
node --version
npm --version
dotnet --version
protoc --version
psql --version
mold --version
gh --version
shellcheck --version
as_runner docker version --format '{{.Server.Version}}'

# The open-file limit, soft then hard, read back where it has to hold: the service manager, the two services that containers inherit
# it from, and the account jobs run as. Both limits must be exactly the number: "infinity" or the 1024 and 524288 of an
# unconfigured system pass any looser comparison. A package whose unit file sets LimitNOFILE itself overrides the manager's default,
# which is why the services are asked as well as the manager; a container takes its limit from containerd's shim, so no container is
# run here, and the build needs no image pulled from a registry for the same fact. This script started before the limit was
# configured, so it still has the old one, and the runner can only have 65536 through pam_limits.
check_nofile() {
  echo "open-file limit of $1 (soft hard): $2"
  [[ $2 == "$nofile $nofile" ]] || { echo "gh-image: the open-file limit of $1 is not $nofile" >&2; exit 1; }
}
check_nofile "the service manager" "$(systemctl show -p DefaultLimitNOFILESoft --value) $(systemctl show -p DefaultLimitNOFILE --value)"
for service in docker.service containerd.service; do
  check_nofile "$service" "$(systemctl show -p LimitNOFILESoft --value "$service") $(systemctl show -p LimitNOFILE --value "$service")"
done
check_nofile "the runner account" "$(as_runner bash -c 'ulimit -Sn; ulimit -Hn' | paste -sd ' ')"
for unit in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service ssh.service ssh.socket; do
  state="$(systemctl is-enabled "$unit" 2>&1 || true)"
  echo "$unit: $state"
  [[ $state == masked ]] || { echo "gh-image: $unit is not masked" >&2; exit 1; }
done

# Cleaned for imaging. The VM that boots from the image must not share a machine id, SSH host keys, cloud-init state or shell history
# with this one. The Google guest agent makes new host keys on first boot, and systemd makes a new machine id when the file is empty.
echo "gh-image: cleaning up"
apt-get clean
rm -rf /var/lib/apt/lists/*
if command -v cloud-init > /dev/null; then
  cloud-init clean --logs
fi
truncate -s 0 /etc/machine-id
rm -f /etc/ssh/ssh_host_*
rm -f /root/.bash_history /home/runner/.bash_history
# Download caches from the installs above, which jobs would rather fill themselves than inherit up to a week stale.
rm -rf /home/runner/.cargo/registry /home/runner/.cargo/git /home/runner/.cache

# Last, and only if every line above succeeded (`set -e` has stopped the script otherwise). The workflow looks for this line. The text
# is assembled so that the whole line is not in this file: if bash ever prints a failing command from here, the log must not contain
# the success line. It is written to the console too, because the relay of a startup script's output to serial port 1 is documented
# only in outline and the workflow must not depend on it.
printf 'gh-image: build %s\n' succeeded
printf 'gh-image: build %s\n' succeeded > /dev/console || true
