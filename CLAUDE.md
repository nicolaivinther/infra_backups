# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PostgreSQL off-site backup system that dumps databases weekly and syncs to a remote server (Marcus) via rsync over a WireGuard VPN. Designed for a Mac mini with a ~200GB database on RAID 0, backing up to a brother's server for redundancy.

## Commands

```bash
# Run backup manually (loads env, then runs the dump script)
./local_cronjobs/backup_postgres.sh

# Or run the dump script directly (requires env vars already exported)
./dump_psql_backup.sh

# View logs (persistent — survives reboot)
tail -f /Users/nicolaitanghoj/pg_backups/pg_backup.log

# Did the last run succeed?
cat /Users/nicolaitanghoj/pg_backups/last_run_status

# Install / reinstall the WireGuard LaunchDaemons (postgres daemon is skipped — see below)
sudo ./local_launchdaemons/install.sh

# PostgreSQL after a reboot: start it by hand (no sudo), then check the watchdog
~/start-pg.sh
tail -5 ~/.cron_monitor/postgres_check.log
tail -20 /Users/nicolaitanghoj/Library/Logs/postgresql16.log

# Tunnel state
sudo wg show
route -n get 192.168.11.3          # must show a utunN interface, not en0
tail -20 /var/log/wireguard-watchdog.log
tail -20 /var/log/wireguard-nicolai-macmini.log

# Restore a backup
gunzip -c database_name_YYYYMMDD_HHMM.dump.gz | pg_restore -U nicolaivinther -d database_name
```

## Architecture

- `dump_psql_backup.sh` - Main script. Runs preflight checks, then for each database in `DB_LIST`: dump → verify → transfer → verify remote → rotate.
- `local_cronjobs/backup_postgres.sh` - Cron wrapper. `cd`s into the repo, sources `.default.env` then `.development.env` (with `set -a` to export), and calls `dump_psql_backup.sh`.
- `local_launchdaemons/` - Root LaunchDaemons: two that keep the WireGuard tunnel alive, plus a PostgreSQL auto-start daemon that is currently **disabled** (TCC, see below), and `install.sh` to deploy them.
- `local_cronjobs/check_postgres.sh` - 5-minute cron check; Sentry alert when PostgreSQL is not accepting connections.
- `.default.env` - Committed defaults (DB user/list, paths, retention, Sentry DSN).
- `.development.env` - Local, gitignored overrides (`REMOTE_USER`, `REMOTE_HOST`).
- `.envrc` - direnv config; loads both env files into the interactive shell.
- Backups stored locally at `/Users/nicolaitanghoj/pg_backups/` and remotely at `/media/antimac/Z/pg_backups/` (Marcus renamed the disk from `Cloud` to `Z` in Aug 2026 — capital Z).
- Runs via cron in two profiles: daily at 03:30 (small operational DBs, `.daily.env`) and weekly Sunday at 10:00 (pinnacle_odds, `.weekly.env`).

### Ordering guarantees

Rotation only runs *after* the new dump has been verified locally and confirmed
byte-for-byte on the remote. A corrupt, truncated, or partially transferred dump
can therefore never evict a known-good backup.

### Preflight

Before dumping anything, the script checks required variables, `pg_dump` on PATH,
local free space (`MIN_FREE_GB`), SSH reachability, and that `REMOTE_PATH` is a
writable *real mount*. This matters: without it, a down tunnel means ~18GB is
dumped before the failure surfaces, and a remote disk that failed to mount after
a rebuild would silently fill the boot volume instead.

### Verification

Two checks, because neither is sufficient alone:
- `gzip -t` validates the whole compressed stream and its CRC — this is what
  catches truncation.
- `pg_restore --list` confirms the archive TOC is structurally readable.
  It reads **only the header**, so it does *not* detect truncation.

`pg_restore --list` exits as soon as it has the header, which kills `gunzip` with
SIGPIPE. That pipeline is deliberately wrapped in `( set +o pipefail; ... )` —
without it, `pipefail` fails every healthy dump.

### Alerting

On any failure the script writes `last_run_status` and sends a Sentry event
(same project as `heartbeat_server`) tagged with the database and the stage that
failed. Set `SENTRY_DSN=""` to disable; the backup still runs.

The `heartbeat_server` service is **not** suitable for this: its
`OFFLINE_THRESHOLD_MINUTES` is global (10 minutes) and `last_seen` is in-memory,
so a weekly ping would be permanently "offline".

## Key Configuration Variables

In `.default.env` (committed):
- `DB_USER` - PostgreSQL role used for `pg_dump` / `pg_restore`.
- `DB_LIST` - Comma-separated string of database names to back up.
- `BACKUP_DIR` - Local backup directory (`/Users/nicolaitanghoj/pg_backups`). **Not `/tmp`** — macOS wipes `/tmp` on reboot, which is how the July 2026 outage went unnoticed.
- `REMOTE_PATH` - Remote destination directory (default: `/media/antimac/Z/pg_backups`).
- `KEEP_LOCAL_BACKUPS` - Local retention per database (default: 1). `0` is valid and means "ship then delete": the local dump is removed once the remote copy is size-verified — the weekly profile uses this so the ~18GB pinnacle_odds dump never occupies local disk between runs.
- `KEEP_REMOTE_BACKUPS` - Remote retention per database (default: 12, ~3 months).
- `MIN_FREE_GB` - Preflight local space floor (default: 45). Profiles override it: daily 10, weekly 25 (one in-flight ~18GB dump plus margin, since the weekly profile deletes the local copy after shipping).
- `SENTRY_DSN` / `SENTRY_ENVIRONMENT` - Failure alerting. Empty DSN disables it.

In `.development.env` (gitignored):
- `REMOTE_USER` - SSH user on the remote server.
- `REMOTE_HOST` - Address of Marcus's backup server as reached over the tunnel: `192.168.11.3`. It sits on Marcus's LAN behind the WireGuard gateway, so it is routed through the VPN (not this Mac mini's own LAN, which is `192.168.86.0/24`).

### Sizing

One full set is ~20.2GB compressed (pinnacle_odds ~17.8GB, basketball_stats
~2.0GB, multisport_stats ~0.4GB, icehockey_stats ~0.02GB). The remote disk is a
938GB dedicated volume, so `KEEP_REMOTE_BACKUPS=12` uses ~242GB.

Retention must comfortably exceed how long a failure can plausibly go
unnoticed. The July 2026 outage ran three weeks undetected — which a retention
of 2 would not have survived.

## WireGuard

- Tunnel config lives at `/usr/local/etc/wireguard/Nicolai_MacMini.conf` (root-owned, 0600 — contains the private key; never commit it).
- Topology: peer endpoint `62.66.180.35:51821`; this Mac mini is `192.168.3.4` inside the tunnel; `192.168.3.1` is the WireGuard gateway; Marcus's backup server is `192.168.11.3` on his LAN behind that gateway.
- **Split tunnel:** `AllowedIPs = 192.168.11.3/32, 192.168.3.1/32`, so only backup traffic uses the VPN — all other traffic (scrapers, LAN, Tailscale) stays on the normal internet. The `DNS =` line from the provider's config is intentionally omitted so the Mac mini keeps its own resolver.
- WireGuard routes by IP (`AllowedIPs`), not by port — there is no per-port toggle. To restrict to a single port, use a firewall on Marcus's server instead.
- The tunnel stays up 24/7; the backup script does not bring it up/down.

### The two daemons

Both live in `local_launchdaemons/` and are installed by `install.sh`:

1. **`com.wireguard.Nicolai_MacMini.plist`** — `wg-quick up` at boot (`RunAtLoad`).
2. **`com.wireguard.watchdog.plist`** — runs `wireguard_watchdog.sh` every 600s to recover a tunnel that dies *while the machine is running*.

**`wg-quick` MUST be referenced as `/opt/homebrew/bin/wg-quick`.** This is an
Apple Silicon Mac; there is no `/usr/local/bin/wg-quick`. The original plist used
the Intel path, so the daemon failed silently at every boot. `EnvironmentVariables/PATH`
is also required, because `wg-quick` is a shell script that shells out to `wg`
and launchd's default PATH excludes Homebrew.

`KeepAlive` is deliberately `false` on the boot daemon: `wg-quick up` exits once
the interface is configured, so `KeepAlive` would relaunch it forever. That is
precisely why the watchdog exists.

**Both plists MUST set `AbandonProcessGroup=true`.** On macOS the tunnel is a
userspace `wireguard-go` process that `wg-quick` backgrounds before exiting.
By default launchd SIGKILLs whatever remains of a job's process group when the
job exits — i.e. it kills the tunnel that was just brought up. This caused the
Aug 2026 outage: the watchdog logged "tunnel back up" every 10 minutes for days,
while each recovered tunnel was killed seconds later, and every backup failed
preflight with an SSH error.

The watchdog recycles the tunnel when the interface is missing, or the route to
`192.168.11.3` is no longer on a `utun` device. If the interface and route are
healthy but the host is unreachable, it waits for **two consecutive** failures
(~20 min) before acting — Marcus's server being down is not a reason to tear
down our end.

## PostgreSQL auto-start — BROKEN, daemon must stay uninstalled (BAS-179)

The cluster's data directory is `/Volumes/MiniData/postgres_data` (external
Thunderbolt SSD), so `brew services start postgresql@16` is **wrong twice**: it
points at the internal default data dir, and it would race the volume mount at
boot.

**There is currently no working auto-start.** After every reboot someone has to
run `~/start-pg.sh` (no sudo) on the mini — a copy of `start-pg.sh` in this repo. `local_cronjobs/check_postgres.sh`
runs from cron every 5 min and raises a Sentry alert when postgres stops
accepting connections (once, then hourly, plus a recovery event), so an
outage surfaces within minutes instead of days — but nothing restarts it.

### Why the LaunchDaemon cannot be used yet

macOS TCC denies launchd-spawned processes access to the removable volume.
`stat` works, content reads fail with EPERM, and `open()` blocks instead of
erroring, so the daemon's postgres hangs in `PostmasterMain → SelectConfigFiles
→ open(postgresql.conf)`. Interactive sessions work because they inherit
Terminal's / Remote Login's Full Disk Access; a launchd job is its own
responsible process and hits the per-binary deny rows:

```
/Library/Application Support/com.apple.TCC/TCC.db (needs sudo):
  kTCCServiceSystemPolicyAllFiles | .../postgresql@16/16.10/bin/postgres | 0
  kTCCServiceSystemPolicyAllFiles | .../postgresql@16/16.10/bin/pg_ctl   | 0
~/Library/Application Support/com.apple.TCC/TCC.db:
  kTCCServiceSystemPolicyRemovableVolumes | .../16.10/bin/pg_ctl         | 0
```

This is not fixable by changing the launcher (LaunchAgent, cron and login
items all hit the same deny). Worse, a hung daemon child can wedge the *live*
postmaster's lock-file recheck — that was the 4-hour outage on 2026-07-31.

`install.sh` therefore **skips** `com.nicolai.postgresql16` unless
`INSTALL_POSTGRES_DAEMON=1` is set, and warns if the plist is present. It was
reinstalled by accident on 2026-08-25 (install.sh used to be unconditional)
and respawned hung postgres processes for a day before being removed.

### To fix (needs a GUI once)

1. Enable Screen Sharing, connect from the MacBook Air via Tailscale
   (`vnc://100.86.3.3`).
2. System Settings → Privacy & Security → Full Disk Access → enable
   `/opt/homebrew/Cellar/postgresql@16/<version>/bin/postgres` and `pg_ctl`
   (they may already be listed, toggled off — that is the deny row).
3. Verify the TCC rows read `2`, and verify with a LaunchDaemon probe that a
   launchd job can `cat /Volumes/MiniData/postgres_data/PG_VERSION`.
4. Only then: `INSTALL_POSTGRES_DAEMON=1 sudo ./local_launchdaemons/install.sh`,
   reboot, and confirm postgres comes up unattended.

**The grant is pinned to the Cellar path.** A Homebrew upgrade (16.10 → 16.11)
moves the binaries, the grant silently stops applying, and postgres will hang
at the next boot. After every `postgresql@16` upgrade, re-grant Full Disk
Access and re-verify before trusting the daemon.

### How the daemon works, once it is allowed to run

`com.nicolai.postgresql16.plist` runs `/usr/local/libexec/start_postgres_minidata.sh`
as `nicolaitanghoj` at boot, before login. The launcher:

- waits up to 5 min for `/Volumes/MiniData` to mount, then exits nonzero so
  launchd retries;
- defers to an already-running postmaster (manual-start era, install-time
  handover) and takes over within 30s of it stopping;
- runs `postgres` in the foreground under launchd supervision. `KeepAlive`
  `SuccessfulExit=false` means a crash restarts it, but a clean `pg_ctl stop`
  stays stopped (restart with
  `sudo launchctl kickstart system/com.nicolai.postgresql16`);
- traps launchd's shutdown SIGTERM and forwards SIGINT, because SIGTERM is
  postgres's "smart" shutdown, which waits forever on idle client connections
  and would end in a SIGKILL after `ExitTimeOut`.

Logs: `/Users/nicolaitanghoj/Library/Logs/postgresql16.log`.

## Incident: July 2026 — three weeks of silent backup loss

Worth understanding, because most of the hardening above exists because of it.

| Date | Event |
|---|---|
| Jun 22 | Split-tunnel migration; tunnel brought up **manually**, masking the broken daemon |
| Jun 28, Jul 5 | Backups succeed on that manually-started tunnel |
| **Jul 10 12:58** | Reboot. Broken daemon can't restore the tunnel |
| Jul 12, 19, 26 | Three backups fail silently |
| Jul 31 | Discovered; daemon path fixed, watchdog + preflight + alerting added |

Four independent failures had to line up: the wrong `wg-quick` path, no
mid-session tunnel recovery, logs on a volume wiped by reboot, and no alert on
failure. Each one is addressed above.

Note that SSH key auth and the remote mount were both **fine** throughout — a
down tunnel makes every symptom look like an auth or mount problem. Check
`route -n get 192.168.11.3` before suspecting credentials.
