//! The image build of a deployment unit: `image/build.sh`, which runs on the build VM, `image/action.yml`, which drives it, and the
//! runner pin they share (docs/architecture/runner-image.md). The scripts run where no test can, so these tests read them, and run
//! the step that deletes images against a stand-in for `gcloud`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

/// Read when the test runs, from the repository root.
fn repo_file(relative: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join(relative);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()))
}

/// `KEY=value` lines, ignoring blanks and comments. The file is also sourced by a shell and read by `sed` in the workflow, so
/// anything cleverer than that is a mistake.
fn parse_env(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| {
            let (key, value) = l
                .split_once('=')
                .unwrap_or_else(|| panic!("not KEY=value: {l:?}"));
            (key.to_owned(), value.to_owned())
        })
        .collect()
}

#[test]
fn the_pin_file_holds_exactly_a_version_and_a_digest() {
    let pin = parse_env(&repo_file("image/runner-version.env"));
    assert_eq!(
        pin.keys().map(String::as_str).collect::<Vec<_>>(),
        ["RUNNER_SHA256", "RUNNER_VERSION"]
    );
    let version = &pin["RUNNER_VERSION"];
    assert!(
        version.split('.').count() == 3
            && version
                .split('.')
                .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit())),
        "RUNNER_VERSION is not major.minor.patch: {version:?}"
    );
    let digest = &pin["RUNNER_SHA256"];
    assert!(
        digest.len() == 64
            && digest
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)),
        "RUNNER_SHA256 is not 64 lowercase hex digits: {digest:?}"
    );
}

/// build.sh takes the pin from instance metadata, so a literal in it would be a third copy that nothing compares.
#[test]
fn build_sh_has_no_pin_of_its_own() {
    let build = repo_file("image/build.sh");
    let code: String = build
        .lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(code.contains("metadata RUNNER_VERSION"));
    assert!(code.contains("metadata RUNNER_SHA256"));
    for line in code.lines().filter(|l| l.contains("RUNNER_VERSION=\"")) {
        assert!(line.contains("$(metadata "), "a literal version: {line}");
    }
    let longest_hex_run = code
        .split(|c: char| !(c.is_ascii_digit() || ('a'..='f').contains(&c)))
        .map(str::len)
        .max()
        .unwrap_or(0);
    assert!(longest_hex_run < 64, "a literal digest");
}

/// The build VM has no identity to write to Cloud Logging with, so the hypervisor's copy of its console is the log that outlives the
/// VM (gcp-github-runners docs/operations/image-rebuilds.md).
#[test]
fn the_build_vm_has_serial_port_logging_enabled() {
    let workflow = repo_file("image/action.yml");
    assert!(workflow.contains("serial-port-logging-enable=true"));
}

/// A stopped VM's serial buffer is reset, so a fetch after the stop is a few bytes. The workflow must not let that replace the log it
/// already holds (run 42365268570).
#[test]
fn the_workflow_never_replaces_the_serial_log_with_a_shorter_answer() {
    let workflow = repo_file("image/action.yml");
    assert!(workflow.contains("if (( new_size < old_size )); then"));
    // The answer is moved over the held copy only after that check, and nowhere else.
    let check = workflow.find("if (( new_size < old_size ))").unwrap();
    let moves: Vec<_> = workflow
        .match_indices("mv serial.log.new serial.log")
        .collect();
    assert_eq!(moves.len(), 1);
    assert!(
        moves[0].0 > check,
        "the log is replaced before the length check"
    );
    // The only redirect into serial.log itself is the empty file made before the first fetch.
    for line in workflow
        .lines()
        .filter(|l| l.contains("> serial.log") && !l.contains("serial.log.new"))
    {
        assert_eq!(
            line.trim(),
            ": > serial.log",
            "something writes into serial.log past the check: {line}"
        );
    }
}

/// Jobs run `sudo apt-get`, and a background apt run would hold the dpkg lock and the CPU under them.
#[test]
fn build_sh_masks_background_apt_and_checks_it() {
    let build = repo_file("image/build.sh");
    let mask = build
        .lines()
        .find(|l| l.starts_with("systemctl mask "))
        .expect("build.sh masks the apt units");
    for unit in [
        "apt-daily.timer",
        "apt-daily-upgrade.timer",
        "apt-daily.service",
        "apt-daily-upgrade.service",
        "unattended-upgrades.service",
    ] {
        assert!(mask.contains(unit), "{unit} is not masked");
    }
    assert!(
        build.contains("[[ $state == masked ]]"),
        "the build does not check that the units ended up masked"
    );
}

/// Nothing should accept a connection on a runner. Ubuntu 24.04 starts `ssh.service` from `ssh.socket` on demand, so masking the
/// service alone would leave the socket listening.
#[test]
fn build_sh_masks_sshd_and_checks_it() {
    let build = repo_file("image/build.sh");
    let mask = build
        .lines()
        .find(|l| l.starts_with("systemctl mask ssh"))
        .expect("build.sh masks the SSH units");
    for unit in ["ssh.service", "ssh.socket"] {
        assert!(mask.contains(unit), "{unit} is not masked");
    }
    let check = build
        .lines()
        .find(|l| l.starts_with("for unit in "))
        .expect("build.sh checks the state of the units it masked");
    for unit in ["ssh.service", "ssh.socket"] {
        assert!(
            check.contains(unit),
            "{unit} is not checked after the build"
        );
    }
    // The host keys are removed for imaging whether or not sshd runs: a VM must not share them with the one it was built on.
    assert!(build.contains("rm -f /etc/ssh/ssh_host_*"));
}

/// GitHub-hosted runners give services and containers 65536 open files, and workflows are written against that; Ubuntu's own soft
/// limit is 1024. The number is written once in build.sh and every place that applies or checks it reads the variable.
#[test]
fn build_sh_sets_the_open_file_limit_before_docker_and_checks_it_where_it_applies() {
    let build = repo_file("image/build.sh");
    assert_eq!(
        build.lines().filter(|l| *l == "nofile=65536").count(),
        1,
        "the limit is not assigned exactly once"
    );
    for written in [
        "DefaultLimitNOFILE=$nofile:$nofile",
        "> /etc/systemd/system.conf.d/nofile.conf",
        "\"* soft nofile $nofile\"",
        "\"* hard nofile $nofile\"",
        "> /etc/security/limits.d/runner.conf",
    ] {
        assert!(build.contains(written), "build.sh does not write {written}");
    }
    // Written before Docker, so that dockerd and containerd start under it and the build needs no restart to prove it.
    let limit = build
        .find("> /etc/systemd/system.conf.d/nofile.conf")
        .unwrap();
    let docker = build.find("\ninstall_docker\n").unwrap();
    assert!(limit < docker, "the limit is written after Docker starts");
    // The places the limit has to hold, each read back from the running system: the service manager, the two services a container
    // inherits it from, and the account jobs run as (through sudo and PAM, not systemd).
    for checked in [
        "systemctl show -p DefaultLimitNOFILESoft --value",
        "systemctl show -p DefaultLimitNOFILE --value",
        "for service in docker.service containerd.service",
        "systemctl show -p LimitNOFILESoft --value",
        "systemctl show -p LimitNOFILE --value",
        "as_runner bash -c",
    ] {
        assert!(build.contains(checked), "build.sh does not check {checked}");
    }
    assert!(
        build.contains("[[ $2 == \"$nofile $nofile\" ]]"),
        "the check does not compare soft and hard limits with the one number"
    );
}

/// The build VM's workflow reads the success line, so the script must be able to print it and only it.
#[test]
fn build_sh_prints_the_success_line_last_and_never_spells_it_out() {
    let build = repo_file("image/build.sh");
    let marker = "gh-image: build succeeded";
    assert!(
        !build.contains(marker),
        "the whole success line is in the script, so a trace of a failing command could print it"
    );
    let workflow = repo_file("image/action.yml");
    assert!(
        workflow.contains(marker),
        "the workflow looks for a different line than the script prints"
    );
    let last_code_line = build
        .lines()
        .rfind(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
        .unwrap();
    assert!(
        last_code_line.contains("/dev/console"),
        "the success line is not the last thing the script does: {last_code_line}"
    );
    assert!(build.contains("trap 'shutdown -h now' EXIT"));
}

/// The lines of the `run: |` block of the action's step with this name, with the block's indentation removed. The steps are written
/// with the name at four spaces and the script at eight, as every step of the action is.
fn workflow_step_script(workflow: &str, step: &str) -> String {
    let lines: Vec<&str> = workflow.lines().collect();
    let header = format!("    - name: {step}");
    let start = lines
        .iter()
        .position(|l| *l == header)
        .unwrap_or_else(|| panic!("image/action.yml has no step named {step:?}"));
    let run = start
        + lines[start..]
            .iter()
            .position(|l| *l == "      run: |")
            .unwrap_or_else(|| panic!("step {step:?} has no `run: |` block"));
    let body: Vec<&str> = lines[run + 1..]
        .iter()
        .take_while(|l| l.is_empty() || l.starts_with("        "))
        .map(|l| l.strip_prefix("        ").unwrap_or(""))
        .collect();
    body.join("\n") + "\n"
}

/// The size of the build VM's disk in GB, from the one place the action defines it: the default of its `build-disk-gb` input.
fn action_build_disk_gb(action: &str) -> u32 {
    let lines: Vec<&str> = action.lines().collect();
    let input = lines
        .iter()
        .position(|l| *l == "  build-disk-gb:")
        .unwrap_or_else(|| panic!("image/action.yml has no input build-disk-gb"));
    let default = lines[input + 1..]
        .iter()
        .take_while(|l| l.starts_with("    "))
        .find_map(|l| l.trim().strip_prefix("default:"))
        .unwrap_or_else(|| panic!("build-disk-gb has no default"));
    default
        .trim()
        .trim_matches('\'')
        .parse()
        .unwrap_or_else(|_| panic!("the default of build-disk-gb is not a number: {default:?}"))
}

/// `--boot-disk-size` in the create step and the size test in the prune step must be one number, or the step that makes images and
/// the step that decides which to keep would disagree about which size is right.
#[test]
fn the_create_and_prune_steps_read_the_same_build_disk_size() {
    let workflow = repo_file("image/action.yml");
    action_build_disk_gb(&workflow);

    let create = workflow_step_script(&workflow, "Create the build VM");
    assert!(
        create.contains("--boot-disk-size \"${BUILD_DISK_GB}GB\""),
        "the build VM's disk is not sized by BUILD_DISK_GB:\n{create}"
    );
    let prune = workflow_step_script(&workflow, "Prune old images");
    assert!(
        prune.contains("\"$BUILD_DISK_GB\""),
        "the prune step does not compare image sizes with BUILD_DISK_GB:\n{prune}"
    );
    // A literal size anywhere else is a second definition.
    for (name, script) in [("create", &create), ("prune", &prune)] {
        let literal = script
            .lines()
            .filter(|l| !l.trim_start().starts_with('#'))
            .find(|l| l.contains("--boot-disk-size 2") || l.contains("--boot-disk-size 5"));
        assert_eq!(literal, None, "the {name} step has a literal disk size");
    }
}

/// Runs the prune step's script against a stand-in for `gcloud` that answers the image listing with `listing` (what
/// `--format 'value(name,diskSizeGb)'` prints: a name and a size per line, newest first) and records every image it is asked to
/// delete. The step deletes images, so what it deletes is tested on the real script and not on a copy of its logic.
struct Prune {
    deleted: Vec<String>,
    succeeded: bool,
    output: String,
}

fn run_prune_step(listing: &str, image: &str, keep: u32) -> Prune {
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;
    use std::sync::atomic::{AtomicU32, Ordering};

    static RUN: AtomicU32 = AtomicU32::new(0);
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "prune-{}-{}",
        std::process::id(),
        RUN.fetch_add(1, Ordering::Relaxed)
    ));
    let bin = dir.join("bin");
    fs::create_dir_all(&bin).unwrap();
    fs::write(dir.join("images"), listing).unwrap();
    fs::write(dir.join("deleted"), "").unwrap();
    fs::write(
        dir.join("prune.sh"),
        workflow_step_script(&repo_file("image/action.yml"), "Prune old images"),
    )
    .unwrap();
    let gcloud = bin.join("gcloud");
    fs::write(
        &gcloud,
        r#"#!/usr/bin/env bash
set -eu
[[ "$1 $2" == "compute images" ]] || { echo "unexpected: $*" >&2; exit 2; }
case $3 in
  list)
    if [[ "$*" == *"value(name,diskSizeGb)"* ]]; then cat "$FAKE_DIR/images"; else echo "a table of the family"; fi ;;
  delete) echo "$4" >> "$FAKE_DIR/deleted" ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&gcloud, fs::Permissions::from_mode(0o755)).unwrap();

    let out = Command::new("bash")
        .arg(dir.join("prune.sh"))
        .env_clear()
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .env("FAKE_DIR", &dir)
        .env("PROJECT_ID", "p")
        .env("FAMILY", "gh-runner")
        .env("BUILD_DISK_GB", "20")
        .env("KEEP", keep.to_string())
        .env("IMAGE", image)
        .output()
        .expect("bash runs");
    let deleted = fs::read_to_string(dir.join("deleted"))
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    let output = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    fs::remove_dir_all(&dir).unwrap();
    Prune {
        deleted,
        succeeded: out.status.success(),
        output,
    }
}

/// The family holds two images of 50 GB next to the newer ones of 20 GB. They go whatever their age, and they do not count towards
/// the number kept, so the newest `KEEP` images of the right size stay.
#[test]
fn prune_deletes_every_image_of_another_disk_size_and_keeps_the_newest_of_the_rest() {
    let listing = "gh-runner-6\t20\ngh-runner-5\t20\ngh-runner-4\t50\ngh-runner-3\t20\n\
                   gh-runner-2\t20\ngh-runner-1\t50\n";
    let run = run_prune_step(listing, "gh-runner-6", 3);
    assert!(run.succeeded, "{}", run.output);
    // 4 and 1 are the wrong size; 2 is the fourth of the right size.
    assert_eq!(run.deleted, ["gh-runner-4", "gh-runner-2", "gh-runner-1"]);
}

#[test]
fn prune_deletes_nothing_when_every_image_is_the_right_size_and_within_the_limit() {
    let run = run_prune_step(
        "gh-runner-3\t20\ngh-runner-2\t20\ngh-runner-1\t20\n",
        "gh-runner-3",
        3,
    );
    assert!(run.succeeded, "{}", run.output);
    assert_eq!(run.deleted, Vec::<String>::new());
}

/// A larger image would not be harmless: the family resolves to its newest image, and a boot disk cannot be smaller than the image.
/// A smaller one is as unwanted, since only one size is built.
#[test]
fn prune_treats_a_smaller_image_like_a_larger_one() {
    let run = run_prune_step("gh-runner-2\t20\ngh-runner-1\t10\n", "gh-runner-2", 3);
    assert!(run.succeeded, "{}", run.output);
    assert_eq!(run.deleted, ["gh-runner-1"]);
}

/// The step is destructive, so it deletes only when the listing shows the image it just made with the size it was made with.
/// Anything else, an empty answer included, would read as "every image has the wrong size".
#[test]
fn prune_deletes_nothing_when_the_new_image_is_not_listed_with_the_build_size() {
    for (listing, why) in [
        ("", "an empty listing"),
        ("gh-runner-1\t20\n", "the new image missing"),
        (
            "gh-runner-2\t50\ngh-runner-1\t20\n",
            "the new image of another size",
        ),
        (
            "gh-runner-2\ngh-runner-1\t20\n",
            "the new image with no size",
        ),
    ] {
        let run = run_prune_step(listing, "gh-runner-2", 3);
        assert!(!run.succeeded, "{why}: the step went on\n{}", run.output);
        assert_eq!(run.deleted, Vec::<String>::new(), "{why}");
    }
}

/// An image whose size cannot be read is neither the right size nor a wrong one, so it is left for a person to look at.
#[test]
fn prune_leaves_an_image_with_no_disk_size_alone_and_does_not_count_it() {
    let run = run_prune_step(
        "gh-runner-3\t20\ngh-runner-2\ngh-runner-1\t20\n",
        "gh-runner-3",
        1,
    );
    assert!(run.succeeded, "{}", run.output);
    assert_eq!(run.deleted, ["gh-runner-1"]);
}

/// The module holds the build disk as the smallest boot disk a tier booting the image may have, and cannot read the action, so the
/// two numbers are compared here.
#[test]
fn the_module_and_the_action_agree_on_the_build_disk() {
    let action = action_build_disk_gb(&repo_file("image/action.yml"));
    let templates = repo_file("instance-templates.tf");
    assert!(
        templates.contains(&format!("  image_disk_gb = {action}\n")),
        "instance-templates.tf's image_disk_gb is not the action's build-disk-gb default ({action})"
    );
}

/// The action and the module name the unit's family and prefix by one rule: the action builds into the family that the module's
/// templates boot, and cloud-iac's `vmimages` condition admits images named `gh-runner-*` only.
#[test]
fn the_action_names_the_family_and_the_prefix_as_the_module_does() {
    let unit = repo_file("unit.tf");
    for rule in [
        r#"name_prefix = var.legacy_names ? "" : "${var.name}-""#,
        r#"image_family = var.legacy_names ? "gh-runner" : "gh-runner-${var.name}""#,
        r#"can(regex("^[a-z]([a-z0-9-]{0,9}[a-z0-9])?$", var.name))"#,
    ] {
        assert!(unit.contains(rule), "unit.tf no longer says {rule}");
    }
    let action = repo_file("image/action.yml");
    for rule in [
        "true) prefix='' family='gh-runner' ;;",
        r#"false) prefix="${UNIT}-" family="gh-runner-${UNIT}" ;;"#,
        "[[ $UNIT =~ ^[a-z]([a-z0-9-]{0,9}[a-z0-9])?$ ]]",
        r#"echo "IMAGE=gh-runner-${NAME_PREFIX}"#,
        r#"echo "INSTANCE=gh-image-${prefix}"#,
    ] {
        assert!(
            action.contains(rule),
            "image/action.yml no longer says {rule}"
        );
    }
}

/// gcp-runner-controller's `runner.sh` runs on the image this builds, and finds the runner, its workspace and the version stamp at
/// these paths. The controller repository holds the same literals in its own test, so changing one side fails a test there or here
/// (docs/architecture/runner-image.md, "The contract with runner.sh").
#[test]
fn build_sh_keeps_the_paths_runner_sh_reads() {
    let build = repo_file("image/build.sh");
    for line in [
        "runner_home=/home/runner/actions-runner\n",
        "runner_work=/home/runner/work\n",
        "> /etc/gh-runner-image/runner-version",
        "install_docker() {",
    ] {
        assert!(build.contains(line), "build.sh no longer has {line:?}");
    }
}
