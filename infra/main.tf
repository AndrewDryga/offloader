# A PUBLIC Cloud Storage bucket hosting the Offloader demo project (examples/public-metrics),
# so anyone can run the container against hosted sample data with ZERO credentials:
#
#   docker run -e OFFLOADER_CONFIG=gs://<bucket>/<prefix>/ -e OFFLOADER_GCS_AUTH=none … offloader
#
# World-readable objects (allUsers → objectViewer); only this Terraform writes to it.

resource "google_storage_bucket" "samples" {
  name          = var.bucket_name
  location      = var.region
  force_destroy = true

  # IAM (not ACLs) governs access; required for a clean allUsers grant.
  uniform_bucket_level_access = true

  # Let the allUsers grant below take effect. The project/org must not *enforce*
  # public-access-prevention, or a public demo bucket is impossible (see README).
  public_access_prevention = "inherited"
}

# Public read. This is a demo bucket — the whole point is anonymous access.
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.samples.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Upload the whole sample project — config .yml AND its companion data (manifest.json +
# the parquet a relative `manifest:` points at). Offloader fetches the tree at boot, so a
# self-contained project serves straight from the bucket.
locals {
  sample_dir   = "${path.module}/../examples/public-metrics"
  sample_files = fileset(local.sample_dir, "**")
}

resource "google_storage_bucket_object" "sample" {
  for_each = local.sample_files

  bucket = google_storage_bucket.samples.name
  name   = "${var.sample_prefix}/${each.value}"
  source = "${local.sample_dir}/${each.value}"
}
