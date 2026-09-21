# oci-arm-hunter — working notes

Hunts for Always-Free Ampere A1 capacity in `ap-mumbai-1`, and (since Sep 2026)
carries the tooling that recovered the data off the instance Oracle reclaimed.

## Current state — 2026-09-20

- **No A1 instance.** Oracle reclaimed `market-genie`; its 47GB boot volume
  survived and is still `AVAILABLE`. The hunt has come back empty for weeks —
  every attempt gets `InternalError`, which is how OCI says "no free-tier A1".
- **`arm-hunter` still runs** every ~30 min via cron, looping internally for
  5.5h per run. Still enabled; it disables itself and opens an issue if it wins.
  It **rotates** `SHAPE_LADDER=2/12,1/6` one size per attempt: a host with one
  spare core refuses 2 OCPU but accepts 1, so asking only for the full
  allowance turns down slots worth taking. Two 1-OCPU instances fit the same
  allowance. Rotation, not both-per-attempt — see the throttling note below.
- **The data is recovered and the app is redeployed elsewhere** (below), so the
  hunt is now optional rather than load-bearing.

## The tenancy

| | |
|---|---|
| Region / AD | `ap-mumbai-1` / `qSPf:AP-MUMBAI-1-AD-1` |
| A1 limits | 2 OCPU / 12 GB — **not** 4/24. Asking for more fails `LimitExceeded`, which is not retryable |
| Block storage | 200 GB Always Free, all volumes combined |
| Free x86 | 2x `VM.Standard.E2.1.Micro`, a pool **separate from Ampere** — obtainable when A1 is not |
| Egress | 10 TB/month free |

`main.tf` is a stale Resource Manager export. It hardcodes AD `qUCo:...` and a
different SSH key; nothing reads it at runtime. Don't trust it.

`oci_instance_key` (gitignored) matches the `SSH_PUBKEY` the workflows inject,
so it opens anything this repo launches.

## Workflows

| | |
|---|---|
| `arm-hunter` | the hunt. Cron restarts a 5.5h internal loop |
| `rescue-volume` | `preflight` / `setup` / `status` / `reset-box` / `teardown` |
| `diagnose` | read-only: instances in all states, limits, volumes, work requests |
| `show-ip`, `open-ports` | on-demand helpers |

`rescue-volume` gets data off the preserved volume **without** A1 capacity: it
clones the boot volume, launches a free E2.1.Micro, and attaches the clone as a
data volume. It works on a clone, never the original, because (a) an attached
volume can't be launched from, so the hunt would be blocked, and (b) mounting
XFS with a dirty log replays the journal and writes, even under `-o ro`.

Cost is measured, not assumed: `preflight` sums every non-terminated volume,
adds what `setup` would create, and prints it against the 200 GB ceiling.
`setup` refuses if it wouldn't fit. Run `teardown` when finished — a live
rescue box + clone sits at 144/200 GB.

## Hard-won gotchas

Each of these cost a failed run. They're fixed in the workflows; don't
reintroduce them.

- **`RUNNING` ≠ booted.** OCI reports `RUNNING` when the hypervisor starts the
  VM. Attaching a volume during early boot is fatal here: the clone is itself a
  bootable Oracle Linux disk whose volume group is *also* named `ocivolume`, so
  dracut sees two VGs with one name, can't resolve root, and loops in initqueue
  forever — the box never opens port 22. Poll TCP 22 before attaching.
- **Match the kernel to the filesystem.** Sorting all Oracle Linux images by
  creation date picks OL7.9, whose 5.4 kernel *cannot mount the volume at all*
  (`Superblock has unknown incompatible features (0x28)`). The volume is OL10
  with modern XFS; it needs 5.14+. Pin the OS version explicitly.
- **At mount time**, rename the clone's VG first, then `nouuid`:
  `vgimportclone --basevgname rescuevg /dev/sdb3` → `vgchange -ay rescuevg` →
  `mount -o ro,nouuid /dev/rescuevg/root /mnt/genie`
- **OCI CLI flags that don't exist the way you'd guess:** boot volumes reject
  `--vpus-per-gb 0` (Lower Cost is block-volume only); it's
  `--preserve-boot-volume false`, not `--no-preserve-boot-volume`; and
  `instance terminate --wait-for-state` takes work-request states
  (`SUCCEEDED`), not `TERMINATED`.
- **E2.1.Micro has 1 GB RAM.** `dnf install` of anything large will thrash it
  into unresponsiveness for minutes. Do heavy work elsewhere.
- **Oracle throttles launches roughly two minutes apart.** The first version of
  the shape ladder tried 2/12 and then 1/6 inside a single attempt, ~105s apart.
  The second call came back `TooManyRequests` **36 times out of 40**, so the
  smaller size — the whole point — was never actually tested; it got a 429, not
  a capacity verdict. Sizes now rotate one per 5-minute attempt, which returns a
  real `InternalError`/success instead. Don't collapse them back into one
  attempt without re-checking the error codes by size.
- **Transient errors are not capacity errors, but both are retryable.** A
  dropped connection is no verdict on capacity; treating it as fatal used to
  kill a 5.5h run with hours of budget left. Genuine failures
  (`NotAuthenticated`, `LimitExceeded`, `InvalidParameter`) must stay fatal.

## What was recovered — 2026-09-20

The volume held an Oracle Linux 10.2 aarch64 system running PM2 with four
processes: `project-tracker`, plus `cie-web` / `cie-api` / `cie-cleanup` from a
second project. PostgreSQL **16** at `/var/lib/pgsql/data`, databases `tracker`
(the app) and `appdb` (the `cie-*` project).

Dumps live at **`~/oracle-recovery/2026-09-20/`** (folder `700`, files `600`),
with a `README.md` covering every file and its restore command. Includes
`pg_dumpall`, per-database plain + custom dumps, the raw PG16 directory, and
the recovered `.env`. Verified by restoring into a clean PG16 and re-counting:
tracker 279 rows, appdb 76 rows — identical to source.

Dumped with a **native arm64** PostgreSQL 16 in Docker on the Mac, matching the
architecture the data was written on. Doing it on the x86 rescue box would have
moved PGDATA across architectures, which PostgreSQL doesn't support.

## Where the app lives now

`tracker` is redeployed, off Oracle entirely:

| | |
|---|---|
| URL | https://clienttracker.someoneelses.cloud (Let's Encrypt, expires 2026-12-19) |
| Host | `200.141.7.74` — Ubuntu 26.04, root via SSH agent key |
| Path | `/opt/clienttracker`, owned by the `clienttracker` system user |
| Service | `clienttracker.service`, enabled at boot, logs to `/var/log/clienttracker.log` |
| Bind | `127.0.0.1:3001` — reachable only through nginx |
| Database | `tracker` on the host's existing PostgreSQL **18**, with a **new** password |
| Proxy | nginx vhost `clienttracker.someoneelses.cloud`, `/ws` carries the upgrade headers the chat needs |

That host is **shared** — `attendance`, `mahapolice`, `techjan.com`, `workwatch`
and the `mbvv` sites also run there, some managed by other sessions. Touch only
`clienttracker`-owned files. nginx owns 80/443, so a second web server is not an
option; add a vhost. Always `nginx -t` before reload, and if it fails because of
somebody else's config, stop rather than editing theirs.

The host is `Etc/UTC` but the app's date math assumes IST, so
`TZ=Asia/Kolkata` is set explicitly in the systemd unit. Don't drop it.

An anonymous request to `/ws` returns 502 — that's correct, not a fault. The
chat server destroys unauthenticated upgrades (`wsServer.ts:48`).

## Why the last instance vanished

Oracle reclaims **idle Always Free** compute: 95th-percentile CPU under 20%
across a 7-day window. `market-genie` ran one lightly-used app and fit that
profile. Anything won next is subject to the same clock — genuine multi-project
load avoids it, a near-idle box does not. Paid accounts are widely said to be
exempt, but I could not confirm that in Oracle's docs.

Oracle also **halved the Always Free A1 allowance** from 4 OCPU / 24 GB to
2 OCPU / 12 GB on 2026-06-15, unannounced. That is why the limits read 2/12 and
not 4/24 — it is not a restriction specific to this tenancy.

## Open items

- **Watch for the first unattended cron run** on the new URL. Both workflows in
  `deepakgodhar/Project-Tracker` were repointed at
  `clienttracker.someoneelses.cloud` (they had been hitting the abandoned Neon
  database via Vercel since July). Manual runs of both pass; a *scheduled* one
  had not yet been observed at the time of writing.
  `CRON_SECRET` in that repo was **rotated during the July migration and never
  updated**, so the URL fix alone returned 401 — the Actions secret was reset to
  match the deployed value. If the app is ever moved again, check both.
- **The hunt** continues. The goal is a *second* machine alongside a paid
  Hostinger VPS, for side projects, at no cost — so PAYG was considered and
  declined, and the 1 GB x86 micros are too small to be useful here.

## Conventions

Personal repo: no AI-authorship trailers in commits, and no employer name
anywhere. Push with the `github-deepakgodhar` SSH alias; scope `gh` with
`-R deepakgodhar/oci-arm-hunter`.
