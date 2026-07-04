# infra — Terraform for the public sample bucket

Creates a **public** Google Cloud Storage bucket in the `warehouse-offloader` project and
uploads the [`examples/public-metrics`](../examples/public-metrics) demo project into it, so
anyone can run Offloader against hosted sample data with **zero credentials**:

```sh
docker run \
  -e OFFLOADER_CONFIG=gs://offloader-public-samples/offloader/ \
  -e OFFLOADER_GCS_AUTH=none \
  -e OFFLOADER_SECRET_KEY_BASE=$(openssl rand -hex 24) \
  -p 4000:4000 \
  ghcr.io/andrewdryga/offloader:edge
# → curl "localhost:4000/v1/endpoints/champion?champion_id=1"
```

`OFFLOADER_GCS_AUTH=none` reads the public bucket unauthenticated (config **and** data), so
there is nothing to clone, build, or authenticate.

## Apply with Terraform Cloud (VCS-driven)

1. Create a **VCS-connected workspace** on this repo with **working directory `infra/`**.
2. Set `cloud.organization` in [`versions.tf`](versions.tf) to your TFC org.
3. Give the workspace GCP credentials for `warehouse-offloader` — a service-account key in the
   `GOOGLE_CREDENTIALS` env var (mark it sensitive), or Workload Identity Federation.
4. Push: TFC plans on PR and applies on merge.

## Notes

- **Public-access prevention:** the bucket grants `allUsers → roles/storage.objectViewer`. The
  project/org must not *enforce* public-access-prevention, or a public demo bucket can't exist.
- **Bucket name is global:** if `offloader-public-samples` is taken, change `bucket_name` in
  [`variables.tf`](variables.tf) — and update the run-box in `site/index.html` +
  `docs/quickstart.md` to match.
- **Scope:** this is a demo-hosting module only — no product infrastructure. Customers run
  Offloader on their own cloud; nothing here provisions that.
