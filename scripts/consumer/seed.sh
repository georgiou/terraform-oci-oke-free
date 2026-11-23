#!/usr/bin/env bash
# Create the state bucket with the OCI CLI so the s3 backend exists before the
# very first `tofu init`. The bootstrap root then imports it and moves it into the
# project compartment. Idempotent.
source "$(dirname "$0")/lib.sh"
need oci "Install the OCI CLI."
PROFILE="$(setting oci_profile)"; TENANCY="$(setting tenancy_ocid)"
NS="$(setting state_namespace)";  BUCKET="$(setting state_bucket)"
BUCKET="${BUCKET:-tofu-state}"

if oci os bucket get --profile "$PROFILE" -ns "$NS" --bucket-name "$BUCKET" >/dev/null 2>&1; then
  green "Bucket $BUCKET already exists."
  exit 0
fi
oci os bucket create --profile "$PROFILE" -ns "$NS" --compartment-id "$TENANCY" \
  --name "$BUCKET" --public-access-type NoPublicAccess --versioning Enabled >/dev/null
green "Created private, versioned bucket $BUCKET (the bootstrap root adopts it)."
