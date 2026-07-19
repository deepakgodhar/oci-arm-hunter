# oci-arm-hunter

Automatically creates an Oracle Cloud **Always-Free Ampere A1 (ARM)** instance,
retrying every ~5 minutes until capacity is available — then stops and notifies you.

Runs entirely on **GitHub Actions** (public repo = unlimited minutes). No machine
of yours needs to stay awake. Your OCI private key is stored as an encrypted
GitHub secret and is never committed.

## How it works

`.github/workflows/arm-hunter.yml` runs `scripts/launch-arm.sh` on a schedule. Each run:

1. **Guard** — if an A1.Flex instance already exists, it stops (nothing to do).
2. **Network** — finds or creates a VCN + subnet + internet gateway (once).
3. **Launch** — attempts `oci compute instance launch`.
4. **Classify** —
   - success → prints the public IP, opens a GitHub issue, disables the workflow;
   - "Out of host capacity" → logs it and exits cleanly to retry next run;
   - any other error → fails the run so GitHub emails you.

## Secrets to set (repo → Settings → Secrets and variables → Actions)

| Secret | What it is |
|---|---|
| `OCI_CLI_USER` | your user OCID |
| `OCI_CLI_TENANCY` | tenancy OCID |
| `OCI_CLI_FINGERPRINT` | API key fingerprint |
| `OCI_CLI_KEY_CONTENT` | the API **private** key (full PEM) |
| `OCI_CLI_REGION` | e.g. `ap-mumbai-1` |

Non-secret config (compartment, availability domain, image, shape, SSH public key)
lives in the workflow file — these are identifiers, not credentials.

## Setup

See the step-by-step in the chat, or `scripts/set-secrets.sh` to load secrets from
a local `.env` you never commit.
