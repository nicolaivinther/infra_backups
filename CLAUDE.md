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

# View logs
tail -f /tmp/pg_backups/pg_backup.log

# Restore a backup
gunzip -c database_name_YYYYMMDD_HHMM.dump.gz | pg_restore -U nicolaivinther -d database_name
```

## Architecture

- `dump_psql_backup.sh` - Main script. Splits `DB_LIST` on commas, then for each database: dumps with `pg_dump -Fc`, pipes through gzip to `<db>_<YYYYMMDD_HHMM>.dump.gz`, rsyncs to the remote, and rotates old backups (keeps `KEEP_LOCAL_BACKUPS` locally, `KEEP_REMOTE_BACKUPS` remotely).
- `local_cronjobs/backup_postgres.sh` - Cron wrapper. `cd`s into the repo, sources `.default.env` then `.development.env` (with `set -a` to export), and calls `dump_psql_backup.sh`.
- `.default.env` - Committed defaults (DB user/list, paths, retention).
- `.development.env` - Local, gitignored overrides (`REMOTE_USER`, `REMOTE_HOST`).
- `.envrc` - direnv config; loads both env files into the interactive shell.
- Backups stored locally at `/tmp/pg_backups/` and remotely at `/media/antimac/Cloud/pg_backups/`.
- Runs via cron weekly: Sunday at 10:00 (`0 10 * * 0`).

## Key Configuration Variables

In `.default.env` (committed):
- `DB_USER` - PostgreSQL role used for `pg_dump` / `pg_restore`.
- `DB_LIST` - Comma-separated string of database names to back up.
- `BACKUP_DIR` - Local backup directory (default: `/tmp/pg_backups`).
- `REMOTE_PATH` - Remote destination directory (default: `/media/antimac/Cloud/pg_backups`).
- `KEEP_LOCAL_BACKUPS` - Local retention per database (default: 1).
- `KEEP_REMOTE_BACKUPS` - Remote retention per database (default: 2).

In `.development.env` (gitignored):
- `REMOTE_USER` - SSH user on the remote server.
- `REMOTE_HOST` - Address of Marcus's backup server as reached over the tunnel: `192.168.11.3`. It sits on Marcus's LAN behind the WireGuard gateway, so it is routed through the VPN (not this Mac mini's own LAN, which is `192.168.86.0/24`).

## WireGuard

- Tunnel config lives at `/usr/local/etc/wireguard/Nicolai_MacMini.conf` (root-owned, 0600 — contains the private key; never commit it).
- Brought up at boot by the LaunchDaemon `/Library/LaunchDaemons/com.wireguard.Nicolai_MacMini.plist` (`wg-quick up`, `RunAtLoad`). The tunnel stays up 24/7; the backup script does not bring it up/down.
- Topology: peer endpoint `62.66.180.35:51821`; this Mac mini is `192.168.3.4` inside the tunnel; `192.168.3.1` is the WireGuard gateway; Marcus's backup server is `192.168.11.3` on his LAN behind that gateway.
- **Split tunnel:** `AllowedIPs = 192.168.11.3/32, 192.168.3.1/32`, so only backup traffic uses the VPN — all other traffic (scrapers, LAN, Tailscale) stays on the normal internet. The `DNS =` line from the provider's config is intentionally omitted so the Mac mini keeps its own resolver.
- WireGuard routes by IP (`AllowedIPs`), not by port — there is no per-port toggle. To restrict to a single port, use a firewall on Marcus's server instead.
- Check status: `sudo wg show`.
