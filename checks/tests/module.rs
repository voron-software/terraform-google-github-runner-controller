//! Checks on the module's own files that `tofu test` cannot make, because they are about which files and blocks exist.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;
use std::path::PathBuf;

fn repo_path(relative: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join(relative)
}

fn repo_file(relative: &str) -> String {
    let path = repo_path(relative);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()))
}

/// The `type.name` of every `resource` and `data` block of the module whose type is a Google one.
fn module_google_objects() -> Vec<String> {
    let dir = repo_path("");
    let mut objects = Vec::new();
    for entry in fs::read_dir(&dir).unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()))
    {
        let path = entry.expect("directory entry").path();
        if path.extension().is_none_or(|e| e != "tf") {
            continue;
        }
        for line in fs::read_to_string(&path)
            .expect("readable module file")
            .lines()
        {
            let mut parts = line.split('"');
            if !matches!(parts.next(), Some("resource " | "data ")) {
                continue;
            }
            if let (Some(kind), _, Some(name)) = (parts.next(), parts.next(), parts.next())
                && kind.starts_with("google_")
            {
                objects.push(format!("{kind}.{name}"));
            }
        }
    }
    objects
}

/// The module names the project and region of every resource itself, so that it does not depend on the provider configuration of
/// whoever calls it, and `tests/placement.tftest.hcl` checks that against a mock provider. A test can only check the resources it
/// lists, so a resource added to the module and left out of the file would pass unchecked. Every one has to be named there.
#[test]
fn the_placement_test_names_every_resource_of_the_module() {
    let objects = module_google_objects();
    assert!(
        objects.len() >= 10,
        "the scan of *.tf found too few resources: {objects:?}"
    );
    let placement = repo_file("tests/placement.tftest.hcl");
    let code: Vec<&str> = placement
        .lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .collect();
    let code = code.join("\n");
    for object in objects {
        assert!(
            code.contains(&object),
            "tests/placement.tftest.hcl checks nothing about {object}: add its project, and its region if it has one"
        );
    }
}
