# infra — Terraform for the public sample bucket

Creates a **public** Google Cloud Storage bucket in the `warehouse-offloader` project and
uploads the [`examples/public-metrics`](../examples/public-metrics) demo project into it, so
anyone can run Offloader against hosted sample data with **zero credentials**:

```sh
offloader serve gs://offloader-public-samples/offloader/
# serve prints the API port it chose (default :8088), then:
# → curl "localhost:8088/v1/endpoints/champion?champion_id=1"
```

A `gs://` bucket defaults to anonymous access (`OFFLOADER_GCS_AUTH=none`), so `serve` reads the
public bucket — config **and** data — with nothing to clone, build, or authenticate. The raw
equivalent is `docker run -e OFFLOADER_CONFIG=gs://…/ -e OFFLOADER_GCS_AUTH=none -p 4000:4000
ghcr.io/andrewdryga/offloader:edge` (the container serves on 4000 unless you set
`OFFLOADER_API_PORT`).

## Apply with Terraform Cloud (VCS-driven)

1. Create a **VCS-connected workspace** on this repo with **working directory `infra/`**. The
   `cloud {}` block in [`versions.tf`](versions.tf) already targets `Dryga/offloader`.
2. Give the workspace GCP access via **Workload Identity Federation** — keyless, no service-account
   key to store. Run the one-time bootstrap as a project admin, then set the vars it prints:

   ```sh
   gcloud auth login
   ./infra/scripts/setup-wif.sh   # creates the WIF pool + OIDC provider + SA, scoped to this workspace
   ```

   Set the three variables from the output as **Environment variables** on the workspace —
   category **"Environment variable", not "Terraform variable"** (dynamic credentials only reads
   the environment; as Terraform variables they're ignored and you get an
   `Invalid value for "audience"` error): `TFC_GCP_PROVIDER_AUTH=true`,
   `TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL`, and `TFC_GCP_WORKLOAD_PROVIDER_NAME` (the bare
   `projects/…` form). The `google` provider then authenticates per run with a short-lived token.
   (A static `GOOGLE_CREDENTIALS` key still works if you prefer it.)
3. Push: TFC plans on push and applies on merge/confirm.

## Notes

- **Public-access prevention:** the bucket grants `allUsers → roles/storage.objectViewer`. The
  project/org must not *enforce* public-access-prevention, or a public demo bucket can't exist.
- **Bucket name is global:** if `offloader-public-samples` is taken, change `bucket_name` in
  [`variables.tf`](variables.tf) — and update the run-box in `site/index.html` +
  `docs/quickstart.md` to match.
- **Scope:** this is a demo-hosting module only — no product infrastructure. Customers run
  Offloader on their own cloud; nothing here provisions that.
