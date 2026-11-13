# The controller and its sweep became optional (unit.tf, `controller_enabled`), which put an index on their addresses. State written
# before that names them without one; these keep that state's objects instead of replacing the service and the job.
moved {
  from = google_cloud_run_v2_service.controller
  to   = google_cloud_run_v2_service.controller[0]
}

moved {
  from = google_cloud_scheduler_job.sweep
  to   = google_cloud_scheduler_job.sweep[0]
}
