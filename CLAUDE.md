# oci-arm-hunter — working notes

Hunts for Always-Free Ampere A1 capacity in `ap-mumbai-1`, and (since Sep 2026)
carries the tooling that recovered the data off the instance Oracle reclaimed.

## Current state — 2026-09-20

- **No A1 instance.** Oracle reclaimed `market-genie`; its 47GB boot volume
  survived and is still `AVAILABLE`. The hunt has come back empty for weeks —
  every attempt gets `InternalError`, which is how OCI says "no free-tier A1".
- **`arm-hunter` still runs** every ~30 min via cron, looping internally for
  5.5h per run. Still enabled; it disables itself and opens an issue if it wins.
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

## Open items

- **Cron URLs are wrong.** Both workflows in `deepakgodhar/Project-Tracker`
  still ping `project-tracker-alpha-three.vercel.app`, so follow-up alerts and
  the daily digest have been running against the abandoned Neon database since
  the July migration. They need to point at the new domain. `CRON_SECRET` is
  already an Actions secret there and matches what's deployed.
- **Teardown not yet run.** The rescue box and clone are still up.
- **The hunt** is still running; decide whether a free ARM box is still wanted.

## Conventions

Personal repo: no AI-authorship trailers in commits, and no employer name
anywhere. Push with the `github-deepakgodhar` SSH alias; scope `gh` with
`-R deepakgodhar/oci-arm-hunter`.
