# Webhook mode's Cloud Tasks queues (github-actions-runner-controller docs/architecture/webhook-mode.md): a paused queue per tier
# whose tasks are the records of the tier's waiting jobs, and one queue of wake-ups that call the controller's POST /wake/<tier>.
#
# They exist in both modes, so that `controller_mode` is a setting of the service alone and switching it back and forth needs no
# queue to be created again: Cloud Tasks refuses a deleted queue's name for seven days. An empty queue costs nothing. Removing a tier
# deletes its queue, and adding the tier back within those seven days fails the apply.
#
# Needs the Cloud Tasks API (cloudtasks.googleapis.com) enabled and the right to manage queues (docs/reference/deployer-requirements.md).

resource "google_cloud_tasks_queue" "waiting" {
  for_each = var.runner_tiers

  # The controller names the queue `waiting-<tier>` (crates/controller/src/tasks.rs there).
  name     = "waiting-${each.key}"
  location = var.location
  project  = var.project_id

  # A record is never delivered: it is only listed and deleted, and its name is what dedups a job's deliveries.
  desired_state = "PAUSED"
}

resource "google_cloud_tasks_queue" "wakeups" {
  name     = "wakeups"
  location = var.location
  project  = var.project_id

  # Said outright, so that a queue paused by hand is resumed by the next apply: a paused one holds wake-ups back.
  desired_state = "RUNNING"

  # A wake-up that fails is retried a few times; the next run of the tier asks for another, and the sweep reconciles every tier
  # within five minutes anyway.
  retry_config {
    max_attempts  = 5
    min_backoff   = "5s"
    max_backoff   = "60s"
    max_doublings = 3
  }
}
