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
# Auth is taken from OCI_CLI_* environment variables (set from GitHub secrets).
# All the non-secret config below is passed in via environment variables too.

set -uo pipefail

# ---- required config (env) -------------------------------------------------
: "${COMPARTMENT_OCID:?set COMPARTMENT_OCID}"
: "${AD:?set AD (availability domain)}"
: "${IMAGE_OCID:?set IMAGE_OCID}"
: "${SSH_PUBKEY:?set SSH_PUBKEY}"

# ---- config with sane defaults --------------------------------------------
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-2}"
MEM_GB="${MEM_GB:-12}"
INSTANCE_DISPLAY_NAME="${INSTANCE_DISPLAY_NAME:-market-genie}"
VCN_DISPLAY_NAME="${VCN_DISPLAY_NAME:-arm-hunter-vcn}"
SUBNET_DISPLAY_NAME="${SUBNET_DISPLAY_NAME:-arm-hunter-subnet}"
VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.0.0/24}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"

log()  { echo "[$(printf '%(%H:%M:%S)T' -1)] $*"; }
# Emit a machine-readable result for the workflow to act on.
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
# 2. Ensure the network exists (find-or-create). Created once, reused forever.
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
# 3. Attempt the launch.
# ---------------------------------------------------------------------------
log "Attempting to launch $SHAPE ($OCPUS OCPU / ${MEM_GB}GB) in $AD ..."
out=$(oci compute instance launch \
  --compartment-id "$COMPARTMENT_OCID" \
  --availability-domain "$AD" \
  --shape "$SHAPE" \
  --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" \
  --image-id "$IMAGE_OCID" \
  --subnet-id "$subnet_id" \
  --assign-public-ip "$ASSIGN_PUBLIC_IP" \
  --display-name "$INSTANCE_DISPLAY_NAME" \
  --metadata "{\"ssh_authorized_keys\":\"$SSH_PUBKEY\"}" \
  --wait-for-state RUNNING 2>&1)
rc=$?

# ---------------------------------------------------------------------------
# 4. Classify the outcome.
# ---------------------------------------------------------------------------
if [ $rc -eq 0 ]; then
  instance_id=$(echo "$out" | jq -r '.data.id' 2>/dev/null)
  public_ip=$(oci compute instance list-vnics --instance-id "$instance_id" \
    --query 'data[0]."public-ip"' --raw-output 2>/dev/null || echo "n/a")
  log "SUCCESS! Instance created: $instance_id"
  log "Public IP: $public_ip"
  echo "PUBLIC_IP=$public_ip" >>"${GITHUB_ENV:-/dev/null}"
  emit success
  exit 0
fi

# Capacity errors are expected & normal — do not fail the job.
if echo "$out" | grep -Eqi "Out of host capacity|InternalError|too many requests|LimitExceeded.*capacity|500"; then
  log "No capacity right now (expected). Will retry next run."
  log "OCI said: $(echo "$out" | tr '\n' ' ' | head -c 400)"
  emit no_capacity
  exit 0
fi

# Anything else is a genuine problem worth alerting on.
log "ERROR: launch failed for a non-capacity reason:"
echo "$out" >&2
emit error
exit 1
