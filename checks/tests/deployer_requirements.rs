//! What the module at the repository root needs of whoever applies it, held to what `metadata.yaml` says (docs/reference/deployer-requirements.md).
//!
//! The metadata names the APIs a customer must enable and the roles the deployer must hold and be allowed to grant. Nothing in
//! OpenTofu can enumerate the resource types of its own module, so a `tofu test` could not notice a new type, and a customer who
//! installs the module would find out from a 403 on the first apply. This reads the module's `.tf` files, so it runs with
//! `cargo test`, which CI already does, and needs neither `tofu` nor credentials.
//!
//! The checks are a function from the module's text and the metadata to a list of problems, so the tests below can feed it a module
//! with a new resource type, or a metadata with an entry removed, and see the message.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use yaml_rust2::{Yaml, YamlLoader};

/// What one resource type needs of the project and the deployer. A type that is not here fails the test, so that whoever adds one
/// has to decide what a customer must enable and grant.
struct Need {
    /// `google_x` for a resource and `data.google_x` for a data source.
    ty: &'static str,
    /// The API the provider calls to create, read and delete it.
    api: &'static str,
    /// Predefined roles, each the narrowest one that holds the permissions the type's CRUD needs. Several hold more than that
    /// (docs/reference/deployer-requirements.md says which and what is narrower), so the list is what a customer can grant without
    /// writing a custom role.
    roles: &'static [&'static str],
}

const NEEDS: &[Need] = &[
    Need {
        ty: "google_cloud_run_v2_service",
        api: "run.googleapis.com",
        // Running the service as `controller-runtime` needs `actAs` on it.
        roles: &["roles/run.admin", "roles/iam.serviceAccountUser"],
    },
    Need {
        ty: "google_cloud_scheduler_job",
        api: "cloudscheduler.googleapis.com",
        // The job signs its token as `controller-sweep`, which needs `actAs` on it.
        roles: &["roles/cloudscheduler.admin", "roles/iam.serviceAccountUser"],
    },
    Need {
        ty: "google_cloud_tasks_queue",
        api: "cloudtasks.googleapis.com",
        roles: &["roles/cloudtasks.queueAdmin"],
    },
    Need {
        ty: "google_compute_firewall",
        api: "compute.googleapis.com",
        roles: &["roles/compute.securityAdmin"],
    },
    Need {
        ty: "google_compute_instance_template",
        api: "compute.googleapis.com",
        // The template names the `runner` account, which needs `actAs` on it.
        roles: &[
            "roles/compute.instanceAdmin.v1",
            "roles/iam.serviceAccountUser",
        ],
    },
    Need {
        ty: "google_project_iam_member",
        // The provider reads and writes the project's policy through Resource Manager, not through the IAM API.
        api: "cloudresourcemanager.googleapis.com",
        roles: &["roles/resourcemanager.projectIamAdmin"],
    },
    Need {
        ty: "google_secret_manager_secret",
        api: "secretmanager.googleapis.com",
        roles: &["roles/secretmanager.admin"],
    },
    Need {
        ty: "google_secret_manager_secret_iam_member",
        api: "secretmanager.googleapis.com",
        roles: &["roles/secretmanager.admin"],
    },
    Need {
        ty: "data.google_secret_manager_secret_version",
        api: "secretmanager.googleapis.com",
        // Reads the metadata of each secret's newest version (`secretmanager.versions.get`), never the payload, to pin its number
        // (secrets.tf). The role is the one the secrets themselves need, so no entry is added to the metadata.
        roles: &["roles/secretmanager.admin"],
    },
    Need {
        ty: "google_service_account",
        api: "iam.googleapis.com",
        roles: &["roles/iam.serviceAccountAdmin"],
    },
    Need {
        ty: "data.google_project",
        api: "cloudresourcemanager.googleapis.com",
        // Only reads the project, which every role above can do.
        roles: &[],
    },
];

/// APIs the module's resources do not call but a running installation does, so a customer enables them before the first job and not
/// after it fails. Each has its reason, which is what keeps the metadata from collecting APIs nobody can account for.
const RUNTIME_ONLY: &[(&str, &str)] = &[
    (
        "batch.googleapis.com",
        "the controller submits one Batch job per runner, and Batch creates the VMs",
    ),
    (
        "logging.googleapis.com",
        "the runner account writes each task's logs (`roles/logging.logWriter`) and Batch reads them back",
    ),
];

const WHAT_TO_UPDATE: &str = "Update checks/tests/deployer_requirements.rs (NEEDS or RUNTIME_ONLY), \
     spec.requirements in metadata.yaml and docs/reference/deployer-requirements.md together";

/// For a mismatch of the grants, which is between the module and one annotation, and which the table of needs does not touch.
const WHAT_TO_UPDATE_GRANTS: &str = "Update grantable-project-roles in metadata.yaml and the roles the module grants \
     in docs/reference/deployer-requirements.md together, so that the roles the deployer may grant are the roles the module grants";

fn repo_path(relative: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join(relative)
}

fn repo_file(relative: &str) -> String {
    let path = repo_path(relative);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()))
}

/// The files of the module that OpenTofu reads and this scan cannot: JSON configuration and `.tofu` files. A resource declared in one
/// would be invisible here, and the test would pass whatever it needs, so their presence fails the test and does not skip them.
fn unreadable_module_files(names: &[String]) -> Vec<String> {
    names
        .iter()
        .filter(|n| n.ends_with(".tf.json") || n.ends_with(".tofu") || n.ends_with(".tofu.json"))
        .cloned()
        .collect()
}

/// Every `*.tf` at the repository root joined, in name order. A subdirectory is not read: `tests/` holds `.tftest.hcl` files, and a
/// module called from the root is refused below, so nothing of the module lives deeper.
fn module_text() -> String {
    let dir = repo_path("");
    let paths: Vec<PathBuf> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()))
        .map(|entry| entry.expect("directory entry").path())
        .collect();
    let names: Vec<String> = paths
        .iter()
        .filter_map(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .collect();
    let unreadable = unreadable_module_files(&names);
    assert!(
        unreadable.is_empty(),
        "the module holds {unreadable:?}, which OpenTofu reads and this scan does not: write the module in .tf files, or extend the scan"
    );
    let mut files: Vec<PathBuf> = paths
        .into_iter()
        .filter(|p| p.extension().is_some_and(|e| e == "tf"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no .tf file in {}", dir.display());
    files
        .iter()
        .map(|p| {
            fs::read_to_string(p).unwrap_or_else(|e| panic!("cannot read {}: {e}", p.display()))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// A top-level `resource`, `data` or `module` block of the module.
#[derive(Debug, PartialEq)]
struct Block {
    kind: String,
    /// The type for a resource or data source, the name for a module.
    ty: String,
    /// The lines between the header and the closing brace, as written.
    body: Vec<String>,
}

/// The text of the line without its `#` or `//` comment. A comment marker inside a string is not one.
fn code(line: &str) -> &str {
    let mut in_string = false;
    let mut previous = ' ';
    for (i, c) in line.char_indices() {
        match c {
            '"' => in_string = !in_string,
            '#' if !in_string => return &line[..i],
            '/' if !in_string && previous == '/' => return &line[..i - 1],
            _ => {}
        }
        previous = c;
    }
    line
}

/// The blocks that start at the left margin and end with a `}` there, which is the only shape `tofu fmt`, checked in CI, allows for a
/// top-level block. A comment that spells out a block header is not one, and a comment after the closing brace or the opening one
/// does not hide the block or the ones after it.
///
/// What this scan does not see, which a review has to: a role or a permission the module's resources need that is computed by an
/// expression (the roles of `google_project_iam_member` must be literals, and the test says so when they are not), an attribute that a
/// provider release starts to need another permission for, and the permissions behind each role in `NEEDS`, which are a judgment
/// written down in docs/reference/deployer-requirements.md and not looked up. A pass means the types are accounted for, not that the
/// lists are complete.
fn blocks(text: &str) -> Vec<Block> {
    let mut found: Vec<Block> = Vec::new();
    let mut open = false;
    for line in text.lines() {
        if open {
            if code(line).trim_end() == "}" {
                open = false;
            } else if let Some(block) = found.last_mut() {
                block.body.push(line.to_owned());
            }
            continue;
        }
        let header = code(line).trim_end();
        let Some((kind, rest)) = header.split_once(' ') else {
            continue;
        };
        if !matches!(kind, "resource" | "data" | "module") || !rest.starts_with('"') {
            continue;
        }
        let ty = rest.split('"').nth(1).unwrap_or_default();
        found.push(Block {
            kind: kind.to_owned(),
            ty: ty.to_owned(),
            body: Vec::new(),
        });
        open = header.ends_with('{');
    }
    found
}

/// The key a block has in `NEEDS`, for the blocks of the provider this module uses and no other: a `random_id` calls no API.
fn need_key(block: &Block) -> Option<String> {
    match block.kind.as_str() {
        "resource" if block.ty.starts_with("google_") => Some(block.ty.clone()),
        "data" if block.ty.starts_with("google_") => Some(format!("data.{}", block.ty)),
        _ => None,
    }
}

/// The `"roles/..."` strings in the code of the block, and a problem for each way the role is set that the scan cannot read: the
/// roles must be literals, written in the block, or the test would pass whatever the module grants.
fn granted_roles(block: &Block) -> (BTreeSet<String>, Vec<String>) {
    let mut roles = BTreeSet::new();
    let mut problems = Vec::new();
    for line in block.body.iter().map(|l| code(l)) {
        for (i, piece) in line.split('"').enumerate() {
            if i % 2 == 1 && piece.starts_with("roles/") {
                roles.insert(piece.to_owned());
            }
        }
        let trimmed = line.trim();
        if let Some(value) = trimmed
            .strip_prefix("role")
            .and_then(|r| r.trim_start().strip_prefix('='))
            .map(str::trim)
            && value != "each.value"
            && !(value.starts_with("\"roles/") && value.ends_with('"'))
        {
            problems.push(format!(
                "a google_project_iam_member sets `role = {value}`, which the scan cannot read: use a literal role, or `each.value` over \
                 a literal list, so that the roles the module grants can be compared with grantable-project-roles in metadata.yaml"
            ));
        }
    }
    if roles.is_empty() {
        problems.push(
            "a google_project_iam_member names no literal \"roles/...\" string, so the roles it grants cannot be read: write them as \
             literals in the block"
                .to_owned(),
        );
    }
    (roles, problems)
}

/// What `metadata.yaml` says, in the three places this reads.
struct Metadata {
    services: BTreeSet<String>,
    /// The roles of every `spec.requirements.roles` entry.
    roles: BTreeSet<String>,
    /// The annotation `grantable-project-roles`: the roles the deployer must be allowed to grant.
    grantable: BTreeSet<String>,
}

fn strings(node: &Yaml, what: &str) -> BTreeSet<String> {
    node.as_vec()
        .unwrap_or_else(|| panic!("metadata.yaml: {what} is not a list"))
        .iter()
        .map(|item| {
            item.as_str()
                .unwrap_or_else(|| panic!("metadata.yaml: {what} holds a non-string"))
                .to_owned()
        })
        .collect()
}

/// Parsed as the blueprint metadata of Google's Cloud Foundation Toolkit, whose schema allows the shapes read here and no other for
/// these keys. The schema itself is checked by `cft blueprint metadata --validate`, not here (docs/reference/deployer-requirements.md).
fn parse_metadata(text: &str) -> Metadata {
    let docs = YamlLoader::load_from_str(text).expect("metadata.yaml is not YAML");
    assert_eq!(docs.len(), 1, "metadata.yaml must hold one document");
    let doc = &docs[0];
    assert_eq!(
        doc["apiVersion"].as_str(),
        Some("blueprints.cloud.google.com/v1alpha1")
    );
    assert_eq!(doc["kind"].as_str(), Some("BlueprintMetadata"));
    assert!(
        doc["spec"]["info"]["title"]
            .as_str()
            .is_some_and(|t| !t.is_empty()),
        "metadata.yaml has no spec.info.title"
    );
    let requirements = &doc["spec"]["requirements"];
    let mut roles = BTreeSet::new();
    for entry in requirements["roles"]
        .as_vec()
        .expect("metadata.yaml: spec.requirements.roles is not a list")
    {
        assert!(
            entry["level"].as_str().is_some(),
            "a spec.requirements.roles entry has no level"
        );
        roles.extend(strings(&entry["roles"], "a spec.requirements.roles entry"));
    }
    let grantable = doc["metadata"]["annotations"]["grantable-project-roles"]
        .as_str()
        .expect("metadata.yaml has no metadata.annotations.grantable-project-roles")
        .split(',')
        .map(|r| r.trim().to_owned())
        .collect();
    Metadata {
        services: strings(&requirements["services"], "spec.requirements.services"),
        roles,
        grantable,
    }
}

fn missing<'a>(
    what: &'a BTreeSet<String>,
    from: &'a BTreeSet<String>,
) -> impl Iterator<Item = &'a String> {
    what.difference(from)
}

/// Everything in which the module's text and the metadata disagree, each as a message that says what to change.
fn problems(module: &str, metadata: &Metadata) -> Vec<String> {
    let mut problems = Vec::new();
    let blocks = blocks(module);

    for block in blocks.iter().filter(|b| b.kind == "module") {
        problems.push(format!(
            "*.tf calls module \"{}\", whose resources this test cannot see: declare them in the module itself, or extend the scan",
            block.ty
        ));
    }

    let mut apis = BTreeSet::new();
    let mut roles = BTreeSet::new();
    let mut granted = BTreeSet::new();
    for block in &blocks {
        let Some(key) = need_key(block) else { continue };
        let Some(need) = NEEDS.iter().find(|n| n.ty == key) else {
            problems.push(format!(
                "*.tf declares `{key}`, which NEEDS has no row for. Say which API it needs and which role a deployer needs to manage it. {WHAT_TO_UPDATE}"
            ));
            continue;
        };
        apis.insert(need.api.to_owned());
        roles.extend(need.roles.iter().map(|r| (*r).to_owned()));
        if need.ty == "google_project_iam_member" {
            let (found, unreadable) = granted_roles(block);
            granted.extend(found);
            problems.extend(unreadable);
        }
        if !metadata.services.contains(need.api) {
            problems.push(format!(
                "`{key}` needs {}, which spec.requirements.services in metadata.yaml does not list. {WHAT_TO_UPDATE}",
                need.api
            ));
        }
        for role in need.roles {
            if !metadata.roles.contains(*role) {
                problems.push(format!(
                    "`{key}` needs the deployer to hold {role}, which spec.requirements.roles in metadata.yaml does not list. {WHAT_TO_UPDATE}"
                ));
            }
        }
    }

    let runtime: BTreeSet<String> = RUNTIME_ONLY
        .iter()
        .map(|(api, _)| (*api).to_owned())
        .collect();
    for api in runtime.iter().filter(|a| !metadata.services.contains(*a)) {
        problems.push(format!(
            "RUNTIME_ONLY has {api}, which spec.requirements.services in metadata.yaml does not list. {WHAT_TO_UPDATE}"
        ));
    }
    let accounted: BTreeSet<String> = apis.union(&runtime).cloned().collect();
    for api in missing(&metadata.services, &accounted) {
        problems.push(format!(
            "metadata.yaml lists the service {api}, which no resource type of the module needs and RUNTIME_ONLY does not explain. {WHAT_TO_UPDATE}"
        ));
    }
    for role in missing(&metadata.roles, &roles) {
        problems.push(format!(
            "metadata.yaml lists the role {role}, which no resource type of the module needs. {WHAT_TO_UPDATE}"
        ));
    }

    // Equal and not only a superset: the annotation is the set a condition on the deployer's IAM writes would admit, and a role
    // left in it after the module stops granting it would admit more than the module needs.
    for role in missing(&granted, &metadata.grantable) {
        problems.push(format!(
            "the module grants {role} with google_project_iam_member, which grantable-project-roles in metadata.yaml does not list, so a deployer limited to the listed roles fails the apply with a 403. {WHAT_TO_UPDATE_GRANTS}"
        ));
    }
    for role in missing(&metadata.grantable, &granted) {
        problems.push(format!(
            "grantable-project-roles in metadata.yaml lists {role}, which the module does not grant with google_project_iam_member. {WHAT_TO_UPDATE_GRANTS}"
        ));
    }
    problems
}

#[test]
fn the_metadata_states_what_the_module_needs() {
    let found = problems(&module_text(), &parse_metadata(&repo_file("metadata.yaml")));
    assert!(found.is_empty(), "\n{}\n", found.join("\n"));
}

/// The page is for the customer and `metadata.yaml` is the source of truth for it, so an entry that is not on the page is a
/// requirement the customer is never told.
#[test]
fn the_page_for_customers_names_every_service_and_role_of_the_metadata() {
    let metadata = parse_metadata(&repo_file("metadata.yaml"));
    let page = repo_file("docs/reference/deployer-requirements.md");
    let entries = metadata
        .services
        .iter()
        .chain(&metadata.roles)
        .chain(&metadata.grantable);
    let absent: Vec<&String> = entries
        .filter(|e| !page.contains(&format!("`{e}`")))
        .collect();
    assert!(
        absent.is_empty(),
        "docs/reference/deployer-requirements.md does not name, in backticks: {absent:?}"
    );
}

const SAMPLE_MODULE: &str = r#"
# resource "google_commented_out" "x" {
resource "google_service_account" "a" {
  account_id = "a"
}

resource "google_project_iam_member" "grants" {
  for_each = toset([
    "roles/one.role", # "roles/in.a.comment"
    "roles/two.role",
  ])
  role = each.value
}

data "google_project" "this" {
}

resource "random_id" "not_google" {
}
"#;

fn sample_metadata() -> Metadata {
    let set = |items: &[&str]| items.iter().map(|s| (*s).to_owned()).collect();
    Metadata {
        services: set(&[
            "iam.googleapis.com",
            "cloudresourcemanager.googleapis.com",
            "batch.googleapis.com",
            "logging.googleapis.com",
        ]),
        roles: set(&[
            "roles/iam.serviceAccountAdmin",
            "roles/resourcemanager.projectIamAdmin",
        ]),
        grantable: set(&["roles/one.role", "roles/two.role"]),
    }
}

#[test]
fn the_scan_reads_the_blocks_of_a_module_and_ignores_comments_and_other_providers() {
    let found: Vec<(String, String)> = blocks(SAMPLE_MODULE)
        .into_iter()
        .map(|b| (b.kind, b.ty))
        .collect();
    assert_eq!(
        found,
        [
            ("resource", "google_service_account"),
            ("resource", "google_project_iam_member"),
            ("data", "google_project"),
            ("resource", "random_id"),
        ]
        .map(|(k, t)| (k.to_owned(), t.to_owned()))
    );
}

#[test]
fn a_comment_after_a_closing_brace_does_not_hide_the_blocks_after_it() {
    let module = "resource \"google_service_account\" \"a\" { # the first\n  account_id = \"a\"\n} # done\n\nresource \"google_pubsub_topic\" \"t\" {\n}\n";
    let found: Vec<String> = blocks(module).into_iter().map(|b| b.ty).collect();
    assert_eq!(found, ["google_service_account", "google_pubsub_topic"]);
    let problems = problems(module, &sample_metadata());
    assert!(
        problems.iter().any(|p| p.contains("`google_pubsub_topic`")),
        "{problems:?}"
    );
}

#[test]
fn a_closing_brace_inside_a_string_is_not_a_comment_marker_or_an_end() {
    // The `}` is indented, so it is not the block's end, and the `#` is inside a string, so it starts no comment.
    let module =
        "resource \"google_service_account\" \"a\" {\n  display_name = \"a # b\"\n  }\n}\n";
    assert_eq!(blocks(module).len(), 1);
}

#[test]
fn files_the_scan_cannot_read_are_refused_and_not_skipped() {
    let names = |n: &[&str]| n.iter().map(|s| (*s).to_owned()).collect::<Vec<String>>();
    assert_eq!(
        unreadable_module_files(&names(&[
            "main.tf",
            "x.tf.json",
            "y.tofu",
            "z.tofu.json",
            "metadata.yaml"
        ])),
        ["x.tf.json", "y.tofu", "z.tofu.json"]
    );
    assert!(unreadable_module_files(&names(&["main.tf", "variables.tf"])).is_empty());
}

#[test]
fn the_module_has_no_file_the_scan_cannot_read() {
    // Panics with the file names if there is one.
    let _ = module_text();
}

#[test]
fn the_sample_module_agrees_with_its_metadata() {
    assert_eq!(
        problems(SAMPLE_MODULE, &sample_metadata()),
        Vec::<String>::new()
    );
}

#[test]
fn a_new_resource_type_without_a_row_fails_and_says_what_to_update() {
    let module = format!("{SAMPLE_MODULE}\nresource \"google_pubsub_topic\" \"t\" {{\n}}\n");
    let found = problems(&module, &sample_metadata());
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("`google_pubsub_topic`"));
    assert!(found[0].contains("NEEDS has no row"));
    assert!(found[0].contains("metadata.yaml"));
    assert!(found[0].contains("docs/reference/deployer-requirements.md"));
}

#[test]
fn a_new_data_source_is_keyed_apart_from_the_resource_of_the_same_name() {
    let module = "data \"google_service_account\" \"a\" {\n}\n";
    let found = problems(module, &sample_metadata());
    assert!(
        found
            .iter()
            .any(|p| p.contains("`data.google_service_account`")),
        "{found:?}"
    );
}

#[test]
fn a_service_removed_from_the_metadata_fails() {
    let mut metadata = sample_metadata();
    metadata.services.remove("iam.googleapis.com");
    let found = problems(SAMPLE_MODULE, &metadata);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("google_service_account") && found[0].contains("iam.googleapis.com"));
}

#[test]
fn a_service_nothing_needs_fails() {
    let mut metadata = sample_metadata();
    metadata.services.insert("pubsub.googleapis.com".to_owned());
    let found = problems(SAMPLE_MODULE, &metadata);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("pubsub.googleapis.com") && found[0].contains("RUNTIME_ONLY"));
}

#[test]
fn a_runtime_service_removed_from_the_metadata_fails() {
    let mut metadata = sample_metadata();
    metadata.services.remove("batch.googleapis.com");
    let found = problems(SAMPLE_MODULE, &metadata);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("RUNTIME_ONLY") && found[0].contains("batch.googleapis.com"));
}

#[test]
fn a_role_the_deployer_needs_but_the_metadata_lacks_fails() {
    let mut metadata = sample_metadata();
    metadata.roles.remove("roles/iam.serviceAccountAdmin");
    let found = problems(SAMPLE_MODULE, &metadata);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("roles/iam.serviceAccountAdmin"));
}

#[test]
fn a_role_the_module_grants_but_the_metadata_does_not_list_as_grantable_fails() {
    let mut metadata = sample_metadata();
    metadata.grantable.remove("roles/two.role");
    let found = problems(SAMPLE_MODULE, &metadata);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("grants roles/two.role"));
}

#[test]
fn a_grantable_role_the_module_no_longer_grants_fails() {
    let mut metadata = sample_metadata();
    metadata.grantable.insert("roles/stale.role".to_owned());
    let found = problems(SAMPLE_MODULE, &metadata);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("roles/stale.role"));
}

#[test]
fn a_role_set_by_an_expression_is_refused_because_it_cannot_be_read() {
    let module = "resource \"google_project_iam_member\" \"g\" {\n  role = var.role\n}\n";
    let found = problems(module, &sample_metadata());
    assert!(
        found.iter().any(|p| p.contains("role = var.role")),
        "{found:?}"
    );
    assert!(
        found.iter().any(|p| p.contains("names no literal")),
        "{found:?}"
    );
}

#[test]
fn a_module_call_is_refused_because_its_resources_are_out_of_sight() {
    let found = problems(
        "module \"inner\" {\n  source = \"./inner\"\n}\n",
        &sample_metadata(),
    );
    assert!(
        found.iter().any(|p| p.contains("module \"inner\"")),
        "{found:?}"
    );
}

#[test]
fn the_metadata_is_blueprint_metadata_with_the_three_statements_read_here() {
    let metadata = parse_metadata(&repo_file("metadata.yaml"));
    assert!(
        !metadata.services.is_empty()
            && !metadata.roles.is_empty()
            && !metadata.grantable.is_empty()
    );
    assert!(
        metadata.grantable.iter().all(|r| r.starts_with("roles/")),
        "grantable-project-roles holds something that is not a role: {:?}",
        metadata.grantable
    );
}
