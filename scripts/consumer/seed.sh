#!/usr/bin/env bash
# Create the state bucket with the OCI CLI so the s3 backend exists before the
# very first `tofu init`. The bootstrap root then imports it and moves it into the
# project compartment. Idempotent.
source "$(dirname "$0")/lib.sh"
need oci "Install the OCI CLI."
need jq "Install jq to verify the bucket and OCI response."
PROFILE="$(setting oci_profile)"; PROFILE="${PROFILE:-DEFAULT}"
AUTH="$(oci_auth_mode "$PROFILE" "$(setting oci_auth)")"
TENANCY="$(setting tenancy_ocid)"; REGION="$(setting region)"
NS="$(setting state_namespace)"; BUCKET="$(setting state_bucket)"
BUCKET="${BUCKET:-tofu-state}"
[ -n "$REGION" ] && [ -n "$NS" ] && [ -n "$TENANCY" ] || die "missing state region, namespace or tenancy"
args=(--profile "$PROFILE" --auth "$AUTH" --region "$REGION")
actual_ns=$(oci os ns get "${args[@]}" --query data --raw-output)
[ "$actual_ns" = "$NS" ] || die "OCI profile does not match configured state namespace"
if result=$(oci os bucket get "${args[@]}" -ns "$NS" --bucket-name "$BUCKET" --output json 2>&1); then
  jq -e --arg tenancy "$TENANCY" '.data | .["compartment-id"] == $tenancy and .["public-access-type"] == "NoPublicAccess" and .versioning == "Enabled"' <<<"$result" >/dev/null \
    || die "existing bucket is not a private versioned root-compartment seed bucket; investigate before continuing"
  objects=$(oci os object list-object-versions "${args[@]}" -ns "$NS" --bucket-name "$BUCKET" --limit 1 --output json)
  jq -e '.data.items | type == "array" and length == 0' <<<"$objects" >/dev/null \
    || die "existing bucket has object versions or could not be verified; use the normal plan or recovery workflow"
  [ -t 0 ] || die "existing seed bucket needs interactive confirmation"
  read -rp "Resume with the existing empty seed bucket $BUCKET? [y/N] " answer
  [[ "$answer" = [yY] ]] || die "existing bucket not adopted"
  green "Using the existing seed bucket $BUCKET."
  exit 0
fi
# A generic 404 can mean denied access. Only accept Object Storage's specific
# missing-bucket error; do not retry an auth/network error as a write.
if ! jq -eRs 'sub("^ServiceError:[\\r\\n ]*"; "") | fromjson | .status == 404 and .code == "BucketNotFound"' <<<"$result" >/dev/null 2>&1; then
  printf '%s\n' "$result" >&2
  die "could not confirm that the seed bucket is missing; no create attempted"
fi
oci os bucket create "${args[@]}" -ns "$NS" --compartment-id "$TENANCY" \
  --name "$BUCKET" --public-access-type NoPublicAccess --versioning Enabled >/dev/null
green "Created private, versioned bucket $BUCKET (the bootstrap root adopts it)."
