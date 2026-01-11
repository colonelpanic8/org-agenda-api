output "service_url" {
  description = "URL of the deployed Cloud Run service"
  value       = google_cloud_run_v2_service.org_agenda_api.uri
}

output "service_name" {
  description = "Name of the Cloud Run service"
  value       = google_cloud_run_v2_service.org_agenda_api.name
}
