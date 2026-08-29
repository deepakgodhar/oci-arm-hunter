#!/usr/bin/env bash
#
# launch-arm.sh — attempt to create an OCI Always-Free Ampere A1 (ARM) instance.
#
# Runs guard + network setup once, then loops launch attempts every
# INTERVAL_SECONDS for up to LOOP_MINUTES (so a single CI run gives hours of
# continuous coverage without depending on GitHub's flaky cron cadence).
#
# Result (written to $GITHUB_OUTPUT as result=...):
#   success      -> instance exists / was created  (exit 0)
#   no_capacity  -> ran out of time, still no slot  (exit 0, retry next run)
#   error        -> auth/config/other real failure  (exit 1, alerts you)

set -uo pipefail

# ---- auth-derived / optional config (env) ---------------------------------
: "${OCI_CLI_TENANCY:?OCI_CLI_TENANCY must be set (from secrets)}"
: "${SSH_PUBKEY:?set SSH_PUBKEY (instance login public key)}"

COMPARTMENT_OCID="${COMPARTMENT_OCID:-$OCI_CLI_TENANCY}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-2}"
MEM_GB="${MEM_GB:-12}"
INSTANCE_DISPLAY_NAME="${INSTANCE_DISPLAY_NAME:-market-genie}"
VCN_DISPLAY_NAME="${VCN_DISPLAY_NAME:-arm-hunter-vcn}"
SUBNET_DISPLAY_NAME="${SUBNET_DISPLAY_NAME:-arm-hunter-subnet}"
VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.0.0/24}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
AD="${AD:-}"                              # auto-detected if blank
IMAGE_OCID="${IMAGE_OCID:-}"              # auto-detected if blank
LOOP_MINUTES="${LOOP_MINUTES:-0}"         # 0 = single attempt; >0 = loop
INTERVAL_SECONDS="${INTERVAL_SECONDS:-300}"

PUBLIC_IP="n/a"

log()  { echo "[$(printf '%(%H:%M:%S)T' -1)] $*"; }
emit() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "result=$1" >>"$GITHUB_OUTPUT"; fi; }

# ---------------------------------------------------------------------------
# One launch attempt across all availability domains.
#   returns 0 = created, 1 = fatal error, 2 = out of capacity (retry)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# A terminated instance can leave its boot volume behind, and Oracle's idle
# reclamation does exactly that - market-genie was terminated but its 47GB volume
# is still AVAILABLE. Relaunching from that volume restores the machine as it was:
# same packages, same data, same authorized_keys. Building from a fresh image
# instead would silently throw all of it away, which is the expensive mistake here.
#
# Prints the id of a detached, AVAILABLE boot volume for this instance, if any.
# ---------------------------------------------------------------------------
find_preserved_boot_volume() {
  local ad="$1"
  oci bv boot-volume list -c "$COMPARTMENT_OCID" --availability-domain "$ad" \
    --query "data[?\"lifecycle-state\"=='AVAILABLE' && starts_with(\"display-name\", '$INSTANCE_DISPLAY_NAME')]|[0].id" \
    --raw-output 2>/dev/null
}

try_launch() {
  local ad out rc instance_id saw_capacity=0 bv
  for ad in "${ADS[@]}"; do
    bv=$(find_preserved_boot_volume "$ad")

    if [ -n "$bv" ] && [ "$bv" != "null" ]; then
      log "Found preserved boot volume - relaunching from it, not from a fresh image."
      log "  $bv"
      # No --image-id and no ssh metadata here: both come from the volume itself,
      # and passing an image alongside a source volume is rejected outright.
      out=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT_OCID" \
        --availability-domain "$ad" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" \
        --source-boot-volume-id "$bv" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip "$ASSIGN_PUBLIC_IP" \
        --display-name "$INSTANCE_DISPLAY_NAME" \
        --wait-for-state RUNNING 2>&1)
      rc=$?
    else
      log "Attempting $SHAPE ($OCPUS OCPU / ${MEM_GB}GB) in $ad ..."
      out=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT_OCID" \
        --availability-domain "$ad" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" \
        --image-id "$IMAGE_OCID" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip "$ASSIGN_PUBLIC_IP" \
        --display-name "$INSTANCE_DISPLAY_NAME" \
        --metadata "{\"ssh_authorized_keys\":\"$SSH_PUBKEY\"}" \
        --wait-for-state RUNNING 2>&1)
      rc=$?
    fi

    if [ $rc -eq 0 ]; then
      # Re-fetch by name; $out is polluted with --wait-for-state progress text.
      instance_id=$(oci compute instance list -c "$COMPARTMENT_OCID" \
        --display-name "$INSTANCE_DISPLAY_NAME" --lifecycle-state RUNNING \
        --query 'data[0].id' --raw-output 2>/dev/null)
      PUBLIC_IP=$(oci compute instance list-vnics --instance-id "$instance_id" \
        --query 'data[0]."public-ip"' --raw-output 2>/dev/null || echo "n/a")
      log "SUCCESS! Instance created in $ad: $instance_id (public IP: $PUBLIC_IP)"
      return 0
    fi

    if echo "$out" | grep -Eqi "Out of host capacity|InternalError|too many requests|LimitExceeded.*capacity|500"; then
      log "No capacity in $ad. OCI said: $(echo "$out" | tr '\n' ' ' | head -c 200)"
      saw_capacity=1
      continue
    fi

    log "ERROR: launch failed in $ad for a non-capacity reason:"
    echo "$out" >&2
    return 1
  done
  [ "$saw_capacity" -eq 1 ] && return 2
  return 1
}

# ---------------------------------------------------------------------------
# 1. Guard: already have a (non-terminated) A1 instance? Then we're done.
# ---------------------------------------------------------------------------
log "Checking for an existing $SHAPE instance..."
existing=$(oci compute instance list -c "$COMPARTMENT_OCID" --all 2>/dev/null \
  | jq -r --arg shape "$SHAPE" \
      '[.data[] | select(.shape==$shape and (."lifecycle-state"|IN("TERMINATED","TERMINATING")|not))] | length' \
  2>/dev/null || echo 0)
if [ "${existing:-0}" -gt 0 ]; then
  log "An $SHAPE instance already exists. Nothing to do — the hunt is over. 🎉"
  emit success; exit 0
fi

# ---------------------------------------------------------------------------
# 2. Discover availability domains + image (live, from THIS tenancy).
# ---------------------------------------------------------------------------
if [ -n "$AD" ]; then
  ADS=("$AD")
else
  log "Detecting availability domains..."
  mapfile -t ADS < <(oci iam availability-domain list -c "$COMPARTMENT_OCID" 2>/dev/null | jq -r '.data[].name')
fi
if [ "${#ADS[@]}" -eq 0 ] || [ -z "${ADS[0]:-}" ]; then
  log "ERROR: could not list availability domains (check auth/region)."; emit error; exit 1
fi
log "Availability domains: ${ADS[*]}"

if [ -z "$IMAGE_OCID" ]; then
  log "Detecting latest Oracle Linux image for $SHAPE..."
  IMAGE_OCID=$(oci compute image list -c "$COMPARTMENT_OCID" \
    --operating-system "Oracle Linux" --shape "$SHAPE" \
    --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output 2>/dev/null)
fi
if [ -z "$IMAGE_OCID" ] || [ "$IMAGE_OCID" = "null" ]; then
  log "ERROR: could not find a compatible image for $SHAPE."; emit error; exit 1
fi
log "Using image: $IMAGE_OCID"

# ---------------------------------------------------------------------------
# 3. Ensure the network exists (find-or-create). Created once, reused forever.
# ---------------------------------------------------------------------------
log "Ensuring VCN '$VCN_DISPLAY_NAME' exists..."
vcn_id=$(oci network vcn list -c "$COMPARTMENT_OCID" --display-name "$VCN_DISPLAY_NAME" \
  --query 'data[0].id' --raw-output 2>/dev/null || true)
if [ -z "${vcn_id}" ] || [ "${vcn_id}" = "null" ]; then
  log "Creating VCN..."
  vcn_id=$(oci network vcn create -c "$COMPARTMENT_OCID" --cidr-block "$VCN_CIDR" \
    --display-name "$VCN_DISPLAY_NAME" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  log "Creating internet gateway..."
  igw_id=$(oci network internet-gateway create -c "$COMPARTMENT_OCID" --vcn-id "$vcn_id" \
    --is-enabled true --display-name "arm-hunter-igw" --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  rt_id=$(oci network vcn get --vcn-id "$vcn_id" --query 'data."default-route-table-id"' --raw-output)
  log "Adding default route 0.0.0.0/0 -> internet gateway..."
  oci network route-table update --rt-id "$rt_id" --force \
    --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"$igw_id\"}]" >/dev/null
fi
log "Ensuring subnet '$SUBNET_DISPLAY_NAME' exists..."
SUBNET_ID=$(oci network subnet list -c "$COMPARTMENT_OCID" --vcn-id "$vcn_id" \
  --display-name "$SUBNET_DISPLAY_NAME" --query 'data[0].id' --raw-output 2>/dev/null || true)
if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" = "null" ]; then
  log "Creating subnet..."
  SUBNET_ID=$(oci network subnet create -c "$COMPARTMENT_OCID" --vcn-id "$vcn_id" \
    --cidr-block "$SUBNET_CIDR" --display-name "$SUBNET_DISPLAY_NAME" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)
fi

# ---------------------------------------------------------------------------
# 4. Attempt loop.
# ---------------------------------------------------------------------------
deadline=$(( LOOP_MINUTES * 60 ))
attempt=0
while :; do
  attempt=$((attempt + 1))
  log "--- Attempt #$attempt (elapsed ${SECONDS}s / budget ${deadline}s) ---"
  try_launch; rc=$?
  case $rc in
    0) echo "PUBLIC_IP=$PUBLIC_IP" >>"${GITHUB_ENV:-/dev/null}"; emit success; exit 0 ;;
    1) emit error; exit 1 ;;
    2) : ;;  # out of capacity — keep trying
  esac

  if [ "$LOOP_MINUTES" -le 0 ] || [ "$SECONDS" -ge "$deadline" ]; then
    log "No capacity within this run's time budget. Will retry on the next run."
    emit no_capacity; exit 0
  fi
  log "Sleeping ${INTERVAL_SECONDS}s before next attempt..."
  sleep "$INTERVAL_SECONDS"
done
