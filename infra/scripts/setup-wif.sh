#!/usr/bin/env bash
# One-time bootstrap: let Terraform Cloud (Dryga/offloader) authenticate to the
# warehouse-offloader GCP project via Workload Identity Federation — no service-account key
# to store or rotate. TFC mints a short-lived OIDC token per run and impersonates the SA below.
#
# Run once with an account that administers the project (Owner, or IAM Admin + Storage Admin):
#
#   gcloud auth login
#   ./infra/setup-wif.sh
#
# Idempotent — safe to re-run. Prints the TFC workspace environment variables at the end.
set -euo pipefail

PROJECT="${PROJECT:-warehouse-offloader}"
TFC_ORG="${TFC_ORG:-Dryga}"
TFC_WORKSPACE="${TFC_WORKSPACE:-offloader}"
POOL_ID="${POOL_ID:-tfc-pool}"
PROVIDER_ID="${PROVIDER_ID:-tfc-oidc}"
SA_ID="${SA_ID:-tfc-offloader}"
SA_EMAIL="${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

# GCP IAM is eventually consistent — a just-created resource can take a few seconds to be
# usable in a policy binding. Retry to ride out that propagation.
retry() {
  local n=1
  until "$@"; do
    if [ "$n" -ge 6 ]; then echo "  ✗ still failing after $n attempts" >&2; return 1; fi
    echo "  … not ready, retrying in 5s ($n/6)" >&2
    n=$((n + 1))
    sleep 5
  done
}

echo "→ project ${PROJECT} · workspace ${TFC_ORG}/${TFC_WORKSPACE}"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
echo "→ project number ${PROJECT_NUMBER}"

echo "→ enabling required APIs"
gcloud services enable \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com storage.googleapis.com \
  --project="$PROJECT"

echo "→ workload identity pool ${POOL_ID}"
gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT" --location=global >/dev/null 2>&1 ||
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --project="$PROJECT" --location=global --display-name="Terraform Cloud"

echo "→ OIDC provider ${PROVIDER_ID} (trusts app.terraform.io, only ${TFC_ORG}/${TFC_WORKSPACE})"
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT" --location=global --workload-identity-pool="$POOL_ID" >/dev/null 2>&1 ||
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --project="$PROJECT" --location=global --workload-identity-pool="$POOL_ID" \
    --display-name="HCP Terraform" \
    --issuer-uri="https://app.terraform.io" \
    --attribute-mapping="google.subject=assertion.sub,attribute.terraform_workspace_name=assertion.terraform_workspace_name,attribute.terraform_organization_name=assertion.terraform_organization_name" \
    --attribute-condition="assertion.terraform_organization_name == '${TFC_ORG}' && assertion.terraform_workspace_name == '${TFC_WORKSPACE}'"

echo "→ service account ${SA_EMAIL}"
gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" >/dev/null 2>&1 ||
  gcloud iam service-accounts create "$SA_ID" \
    --project="$PROJECT" --display-name="Terraform Cloud — offloader"

# Wait for the SA to become referenceable before binding roles to it (see retry() above).
echo "→ waiting for the service account to propagate"
for _ in $(seq 1 12); do
  if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" >/dev/null 2>&1; then break; fi
  sleep 3
done

echo "→ grant the SA storage-admin (create the demo bucket + set its allUsers IAM)"
retry gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.admin" --condition=None >/dev/null

echo "→ let ONLY the ${TFC_WORKSPACE} workspace's federated identity impersonate the SA"
retry gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project="$PROJECT" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.terraform_workspace_name/${TFC_WORKSPACE}" >/dev/null

PROVIDER_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
cat <<EOF

✅ Workload Identity Federation is ready.

On the TFC workspace ${TFC_ORG}/${TFC_WORKSPACE}, add these three as ENVIRONMENT variables —
category "Environment variable", NOT "Terraform variable". Dynamic credentials only reads the
environment; as Terraform variables they're ignored (and Terraform warns "undeclared variable").
The provider name is the bare projects/… form (TFC adds the //iam.googleapis.com/ prefix itself).

  TFC_GCP_PROVIDER_AUTH               true
  TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL   ${SA_EMAIL}
  TFC_GCP_WORKLOAD_PROVIDER_NAME      ${PROVIDER_NAME}

Then remove any GOOGLE_CREDENTIALS variable and queue a new run.
EOF
