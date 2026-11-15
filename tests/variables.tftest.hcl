# Input validation. Each run feeds one bad value and expects exactly that variable's validation to reject it.
mock_provider "google" {}

override_resource {
  target = google_service_account.controller_runtime
  values = {
    email  = "controller-runtime@github-runners-prd.iam.gserviceaccount.com"
    member = "serviceAccount:controller-runtime@github-runners-prd.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.runner
  values = {
    email  = "runner@github-runners-prd.iam.gserviceaccount.com"
    member = "serviceAccount:runner@github-runners-prd.iam.gserviceaccount.com"
  }
}

variables {
  # The legacy unit, whose names are the ones these tests were written against; tests/units.tftest.hcl covers a named unit.
  name                       = "prd"
  legacy_names               = true
  project_id                 = "github-runners-prd"
  location                   = "europe-west3"
  batch_location             = "europe-west10"
  github_org                 = "voron-software"
  github_app_id              = 1
  github_app_installation_id = 2
  github_runner_group_id     = 3
  controller_image           = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0"
  runner_tiers = {
    gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
  }
}

run "checked_in_sentinels_are_accepted" {
  # A deployment's tfvars ships 0 for the three GitHub ids until the App exists; the first apply must not be blocked by them.
  command = plan

  variables {
    github_app_id              = 0
    github_app_installation_id = 0
    github_runner_group_id     = 0
  }
}

run "accepts_several_tiers_including_one_named_like_another_s_prefix" {
  # `gcp` is a prefix of the other labels. The labels are compared whole, so that is no clash. That a caller's values pass these
  # validations is checked by the caller's own plan.
  command = plan

  variables {
    runner_tiers = {
      gcp-small  = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 1 }
      gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
      gcp-large  = { machine_type = "e2-standard-4", boot_disk_gb = 40, max_runners = 1 }
      gcp-xlarge = { machine_type = "e2-standard-8", boot_disk_gb = 60, max_runners = 1 }
      gcp        = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    }
  }
}

run "accepts_the_disk_bounds_and_the_longest_label" {
  command = plan

  variables {
    runner_tiers = {
      smallest = { machine_type = "e2-medium", boot_disk_gb = 10, max_runners = 1 }
      largest  = { machine_type = "e2-medium", boot_disk_gb = 2000, max_runners = 1 }
      custom   = { machine_type = "e2-custom-4-8192", boot_disk_gb = 20, max_runners = 1 }
      # 28 characters, the longest label whose instance template name keeps the prefix within 37 (instance-templates.tf). The
      # controller itself would take up to 39, the most a runner name `runner-<label>-<16 hex digits>` leaves within Batch's 63.
      aaaaaaaaaaaaaaaaaaaaaaaaaaaa = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 1 }
    }
  }
}

run "rejects_no_tiers" {
  command = plan

  variables {
    runner_tiers = {}
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_self_hosted_as_a_tier_label" {
  command = plan

  variables {
    runner_tiers = {
      self-hosted = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_an_uppercase_tier_label" {
  # GitHub compares labels without regard to case, so `GCP-Large` next to `gcp-large` would be one label twice.
  command = plan

  variables {
    runner_tiers = {
      gcp-large = { machine_type = "e2-standard-4", boot_disk_gb = 40, max_runners = 1 }
      GCP-Large = { machine_type = "e2-standard-4", boot_disk_gb = 40, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_tier_label_that_is_not_a_label_value" {
  command = plan

  variables {
    runner_tiers = {
      "gcp large" = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_tier_label_longer_than_a_runner_name_allows" {
  command = plan

  variables {
    runner_tiers = {
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_tier_label_with_a_dash_at_either_end" {
  # The runners' names would end the label with a dash next to the one before the random part, and the controller would not read
  # them as its own.
  command = plan

  variables {
    runner_tiers = {
      "-gcp" = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
      "gcp-" = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_tier_label_too_long_for_its_template_name" {
  # 29 characters is a label the controller accepts, but `gh-tier-<label>-` would be 38 and Terraform appends 26 to a Compute Engine
  # name that may be 63: the provider would shorten the suffix and risk a collision between templates.
  command = plan

  variables {
    runner_tiers = {
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaa = { machine_type = "e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_machine_type_that_is_not_a_name" {
  command = plan

  variables {
    runner_tiers = {
      gcp-medium = { machine_type = "zones/europe-west10-a/machineTypes/e2-standard-2", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_an_empty_machine_type" {
  command = plan

  variables {
    runner_tiers = {
      gcp-medium = { machine_type = "", boot_disk_gb = 20, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_boot_disk_below_the_minimum" {
  command = plan

  variables {
    runner_tiers = {
      gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 9, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_boot_disk_above_the_maximum" {
  command = plan

  variables {
    runner_tiers = {
      gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 2001, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_fractional_boot_disk" {
  command = plan

  variables {
    runner_tiers = {
      gcp-medium = { machine_type = "e2-standard-2", boot_disk_gb = 20.5, max_runners = 1 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "rejects_a_fractional_max_run_time" {
  command = plan

  variables {
    runner_max_run_seconds = 1.5
  }

  expect_failures = [var.runner_max_run_seconds]
}

run "rejects_a_zero_max_run_time" {
  command = plan

  variables {
    runner_max_run_seconds = 0
  }

  expect_failures = [var.runner_max_run_seconds]
}

run "rejects_a_docker_hub_namespace" {
  # `team` has no dot, no port and is not `localhost`, so Docker reads it as a Docker Hub namespace and not as a registry.
  command = plan

  variables {
    controller_image = "team/controller:v0.1.0"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_docker_hub_library_image" {
  command = plan

  variables {
    controller_image = "library/nginx:v1.2.3"
  }

  expect_failures = [var.controller_image]
}

run "accepts_localhost_as_the_registry" {
  command = plan

  variables {
    controller_image = "localhost/controller:v0.1.0"
  }
}

run "accepts_localhost_with_a_port" {
  command = plan

  variables {
    controller_image = "localhost:5000/team/controller:v0.1.0"
  }
}

# The controller image must be pinned (variables.tf): the module has no pipeline to roll an image out, so a reference that moves would
# run different code on different days. These runs feed one value each and expect exactly that variable's validation to take it or
# refuse it.
run "accepts_a_release_tag" {
  # What a release is: the tag the Build workflow adds to the image (github-actions-runner-controller docs/operations/releases.md).
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0"
  }
}

run "accepts_a_release_tag_with_several_digits" {
  # Each part of the version is a whole number of any length.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v10.200.3000"
  }
}

run "accepts_a_digest" {
  # A digest names the bits whatever the registry does, so it is the way to run an image that has no release.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}

run "accepts_a_release_tag_with_its_digest" {
  # Both together: Cloud Run pulls the digest, and the tag says which release it is.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}

run "accepts_a_registry_of_the_callers_own" {
  # A copy in another registry, with a port and a nested path, is as pinned as the original.
  command = plan

  variables {
    controller_image = "registry.example.com:5000/team/runners/controller:v1.2.3"
  }
}

run "rejects_latest" {
  # A tag that moves: the same apply would run different code on different days.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:latest"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_bare_repository" {
  # No tag and no digest means `latest`.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_commit_tag" {
  # The publisher's per-commit tags are not releases, and a digest says the same thing without trusting the registry.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:45c7acb0123456789abcdef0123456789abcdef0"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_tag_without_the_v" {
  # A release tag has the v, and one without it is not one the Build workflow makes.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:0.1.0"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_version_with_two_parts" {
  # A release is X.Y.Z.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_version_with_a_leading_zero" {
  # Not a semantic version.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v01.2.3"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_pre_release_version" {
  # The Build workflow refuses a pre-release, so none is a release.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.2.0-rc.1"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_branch_tag" {
  # A tag that moves with a branch.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:main"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_release_tag_followed_by_a_second_tag" {
  # Only one tag, and nothing after it but a digest.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0:latest"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_short_digest" {
  # A digest is 64 hex digits.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller@sha256:0123456789abcdef"
  }

  expect_failures = [var.controller_image]
}

run "rejects_an_uppercase_digest" {
  # The digest is lowercase hex.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller@sha256:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
  }

  expect_failures = [var.controller_image]
}

run "rejects_another_digest_algorithm" {
  # Only sha256, which is what registries print.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller@sha512:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_name_with_no_registry" {
  # A bare name has no registry host: the pin would not say where it is pulled from.
  command = plan

  variables {
    controller_image = "controller:v0.1.0"
  }

  expect_failures = [var.controller_image]
}

run "rejects_an_empty_image" {
  # An empty value would otherwise reach Cloud Run as a service with no image.
  command = plan

  variables {
    controller_image = ""
  }

  expect_failures = [var.controller_image]
}

run "rejects_an_image_with_a_scheme" {
  # A reference has no scheme.
  command = plan

  variables {
    controller_image = "https://europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0"
  }

  expect_failures = [var.controller_image]
}

run "rejects_an_image_with_spaces" {
  # Trailing whitespace is not part of a reference.
  command = plan

  variables {
    controller_image = "europe-west3-docker.pkg.dev/github-runners-prd/cloudrun/controller:v0.1.0 "
  }

  expect_failures = [var.controller_image]
}

run "rejects_a_fractional_app_id" {
  command = plan

  variables {
    github_app_id = 1.5
  }

  expect_failures = [var.github_app_id]
}

run "accepts_the_sweep_grace_bounds" {
  command = plan

  variables {
    sweep_grace_seconds = 1
  }
}

run "accepts_the_longest_sweep_grace" {
  command = plan

  variables {
    sweep_grace_seconds = 3600
  }
}

run "rejects_no_sweep_grace" {
  command = plan

  variables {
    sweep_grace_seconds = 0
  }

  expect_failures = [var.sweep_grace_seconds]
}

run "rejects_a_sweep_grace_over_an_hour" {
  command = plan

  variables {
    sweep_grace_seconds = 3601
  }

  expect_failures = [var.sweep_grace_seconds]
}

run "rejects_a_fractional_sweep_grace" {
  command = plan

  variables {
    sweep_grace_seconds = 1.5
  }

  expect_failures = [var.sweep_grace_seconds]
}

run "rejects_a_max_runners_out_of_bounds_or_fractional" {
  command = plan

  variables {
    runner_tiers = {
      none     = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 0 }
      too_many = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 101 }
      half     = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 1.5 }
    }
  }

  expect_failures = [var.runner_tiers]
}

run "accepts_the_max_runners_bounds" {
  command = plan

  variables {
    runner_tiers = {
      one     = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 1 }
      hundred = { machine_type = "e2-medium", boot_disk_gb = 20, max_runners = 100 }
    }
  }
}

run "rejects_a_poll_timeout_out_of_bounds" {
  command = plan

  variables {
    scaleset_poll_timeout_ms = 99
  }

  expect_failures = [var.scaleset_poll_timeout_ms]
}
