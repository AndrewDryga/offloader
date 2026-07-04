output "bucket" {
  description = "Name of the public sample bucket."
  value       = google_storage_bucket.samples.name
}

output "config_url" {
  description = "Point OFFLOADER_CONFIG here, with OFFLOADER_GCS_AUTH=none."
  value       = "gs://${google_storage_bucket.samples.name}/${var.sample_prefix}/"
}
