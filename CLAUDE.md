# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PostgreSQL off-site backup system that dumps databases nightly and syncs to a remote server (Marcus) via rsync over WireGuard VPN. Designed for a Mac mini with ~200GB database on RAID 0, backing up to brother's server for redundancy.

## Commands

```bash
# Run backup manually
./backup.sh

# View logs
tail -f /tmp/pg_backups/pg_backup.log

# Restore a backup
gunzip -c database_name_YYYYMMDD_HHMM.dump.gz | pg_restore -U nicolaivinther -d database_name
```

## Architecture

- `backup.sh` - Main script that iterates through databases in `DB_LIST`, dumps each with `pg_dump -Fc`, compresses with gzip, rsyncs to remote, and rotates old backups (keeps 2)
- `config.env` - Runtime configuration (not committed; copy from `config.env.example`)
- Backups stored locally at `/tmp/pg_backups/` and remotely at `/media/antimac/Cloud/`
- Runs via cron at 01:00 daily

## Key Configuration Variables

All in `config.env`:
- `DB_LIST` - Array of database names to back up
- `REMOTE_HOST` - WireGuard IP of remote server (default: 10.0.0.2)
- `KEEP_BACKUPS` - Retention count for rotation (default: 2)
