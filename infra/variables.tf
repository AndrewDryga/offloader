variable "project" {
  description = "GCP project that hosts the public sample bucket."
  type        = string
  default     = "warehouse-offloader"
}

variable "region" {
  description = "Location for the bucket (a region like us-central1, or a multi-region like US)."
  type        = string
  default     = "US"
}

variable "bucket_name" {
  description = <<-EOT
    Globally-unique name for the PUBLIC sample bucket. The zero-setup run-box in
    site/index.html and docs/quickstart.md reference this exact name — change both if you
    change this.
  EOT
  type        = string
  default     = "offloader-public-samples"
}

variable "sample_prefix" {
  description = "Object-name prefix the sample project lives under: OFFLOADER_CONFIG=gs://<bucket>/<prefix>/"
  type        = string
  default     = "offloader"
}
