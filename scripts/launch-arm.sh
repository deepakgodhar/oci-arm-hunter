#!/usr/bin/env bash
#
# launch-arm.sh — attempt to create an OCI Always-Free Ampere A1 (ARM) instance.
#
# Designed to be run repeatedly (e.g. from a GitHub Actions cron). It is fully
# idempotent and safe to run over and over:
#   - if an A1.Flex instance already exists  -> reports success, does nothing
#   - if capacity is unavailable             -> reports "no_capacity", exits 0
#   - if the launch succeeds                 -> reports "success" + public IP
#   - on any real error (auth/config/quota)  -> exits 1 so CI alerts you
#
# Everything account-specific (compartment, availability domain, image) is
# derived LIVE from the account behind the OCI_CLI_* credentials, so it always
# matches the tenancy you authenticated as. Only the instance SSH public key
# and the shape sizing are passed in.

set -uo pipefail

# ---- auth-derived / optional config (env) ---------------------------------
: "${OCI_CLI_TENANCY:?OCI_CLI_TENANCY must be set (from secrets)}"
: "${SSH_PUBKEY:?set SSH_PUBKEY (instance login public key)}"

# Compartment defaults to the tenancy root (correct for Always-Free).
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
# AD and IMAGE_OCID are auto-detected below if left blank.
AD="${AD:-}"
IMAGE_OCID="${IMAGE_OCID:-}"

log()  { echo "[$(printf '%(%H:%M:%S)T' -1)] $*"; }
emit() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "result=$1" >>"$GITHUB_OUTPUT"; fi; }

# ---------------------------------------------------------------------------
# 1. Guard: is there already a (non-terminated) A1 instance? Then we're done.
# ---------------------------------------------------------------------------
log "Checking for an existing $SHAPE instance..."
existing=$(oci compute instance list -c "$COMPARTMENT_OCID" --all 2>/dev/null \
  | jq -r --arg shape "$SHAPE" \
      '[.data[] | select(.shape==$shape and (."lifecycle-state"|IN("TERMINATED","TERMINATING")|not))] | length' \
  2>/dev/null || echo 0)

if [ "${existing:-0}" -gt 0 ]; then
  log "An $SHAPE instance already exists. Nothing to do — the hunt is over. 🎉"
  emit success
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Discover availability domains and image (live, from THIS tenancy).
# ---------------------------------------------------------------------------
if [ -n "$AD" ]; then
  ADS=("$AD")
else
  log "Detecting availability domains..."
  mapfile -t ADS < <(oci iam availability-domain list -c "$COMPARTMENT_OCID" 2>/dev/null \
    | jq -r '.data[].name')
fi
if [ "${#ADS[@]}" -eq 0 ] || [ -z "${ADS[0]:-}" ]; then
  log "ERROR: could not list availability domains (check auth/region)."; emit error; exit 1
fi
log "Availability domains: ${ADS[*]}"

if [ -z "$IMAGE_OCID" ]; then
  log "Detecting latest Oracle Linux image for $SHAPE..."
  IMAGE_OCID=$(oci compute image list -c "$COMPARTMENT_OCID" \
    --operating-system "Oracle Linux" --shape "$SHAPE" \
    --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --raw-output 2>/dev/null)
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
    --display-name "$VCN_DISPLAY_NAME" --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)

  log "Creating internet gateway..."
  igw_id=$(oci network internet-gateway create -c "$COMPARTMENT_OCID" --vcn-id "$vcn_id" \
    --is-enabled true --display-name "arm-hunter-igw" --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)

  rt_id=$(oci network vcn get --vcn-id "$vcn_id" --query 'data."default-route-table-id"' --raw-output)
  log "Adding default route 0.0.0.0/0 -> internet gateway..."
  oci network route-table update --rt-id "$rt_id" --force \
    --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"$igw_id\"}]" >/dev/null
fi

log "Ensuring subnet '$SUBNET_DISPLAY_NAME' exists..."
subnet_id=$(oci network subnet list -c "$COMPARTMENT_OCID" --vcn-id "$vcn_id" \
  --display-name "$SUBNET_DISPLAY_NAME" --query 'data[0].id' --raw-output 2>/dev/null || true)

if [ -z "${subnet_id}" ] || [ "${subnet_id}" = "null" ]; then
  log "Creating subnet..."
  subnet_id=$(oci network subnet create -c "$COMPARTMENT_OCID" --vcn-id "$vcn_id" \
    --cidr-block "$SUBNET_CIDR" --display-name "$SUBNET_DISPLAY_NAME" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)
fi

# ---------------------------------------------------------------------------
# 4. Attempt the launch, trying each availability domain in turn.
# ---------------------------------------------------------------------------
saw_capacity_error=0
for ad in "${ADS[@]}"; do
  log "Attempting $SHAPE ($OCPUS OCPU / ${MEM_GB}GB) in $ad ..."
  out=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT_OCID" \
    --availability-domain "$ad" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" \
    --image-id "$IMAGE_OCID" \
    --subnet-id "$subnet_id" \
    --assign-public-ip "$ASSIGN_PUBLIC_IP" \
    --display-name "$INSTANCE_DISPLAY_NAME" \
    --metadata "{\"ssh_authorized_keys\":\"$SSH_PUBKEY\"}" \
    --wait-for-state RUNNING 2>&1)
  rc=$?

  if [ $rc -eq 0 ]; then
    instance_id=$(echo "$out" | jq -r '.data.id' 2>/dev/null)
    public_ip=$(oci compute instance list-vnics --instance-id "$instance_id" \
      --query 'data[0]."public-ip"' --raw-output 2>/dev/null || echo "n/a")
    log "SUCCESS! Instance created in $ad: $instance_id"
    log "Public IP: $public_ip"
    echo "PUBLIC_IP=$public_ip" >>"${GITHUB_ENV:-/dev/null}"
    emit success
    exit 0
  fi

  if echo "$out" | grep -Eqi "Out of host capacity|InternalError|too many requests|LimitExceeded.*capacity|500"; then
    log "No capacity in $ad (expected). OCI said: $(echo "$out" | tr '\n' ' ' | head -c 300)"
    saw_capacity_error=1
    continue
  fi

  # Non-capacity error -> genuine problem, alert immediately.
  log "ERROR: launch failed in $ad for a non-capacity reason:"
  echo "$out" >&2
  emit error
  exit 1
done

if [ "$saw_capacity_error" -eq 1 ]; then
  log "No capacity in any AD right now. Will retry next run."
  emit no_capacity
  exit 0
fi

log "ERROR: no launch attempt succeeded and no capacity error was seen."
emit error
exit 1
