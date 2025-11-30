# PostgreSQL Off-Site Backup System

Automated PostgreSQL database dumps synced to a remote server via WireGuard VPN.

## Overview

This repository provides a reliable off-machine backup solution for PostgreSQL databases. Backups are:
- Dumped weekly using `pg_dump`
- Compressed with gzip
- Transferred to a remote server via rsync over WireGuard
- Rotated to keep only the 2 most recent backups (local + remote)

### Current Setup
- **Source**: Mac mini with 2x 1TB disks (RAID 0)
- **Database size**: ~200 GB
- **Destination**: Brother's server (Marcus)
- **Connection**: WireGuard VPN

## Prerequisites

1. **SSH key authentication** configured between Mac mini and remote server:
   ```bash
   ssh-copy-id user@remote-host
   ```

2. **WireGuard VPN** connection active (auto-starts via LaunchDaemon)

3. **PostgreSQL** with `pg_dump` available

4. **rsync** installed on both machines

5. **direnv** installed for environment management

## Installation

1. Clone this repository:
   ```bash
   git clone <repo-url> ~/dev/infra_backups
   cd ~/dev/infra_backups
   ```

2. Configure environment files:
   ```bash
   # Edit .default.env with shared defaults
   # Edit .development.env with your local overrides (gitignored)
   direnv allow
   ```

3. Make scripts executable:
   ```bash
   chmod +x dump_psql_backup.sh
   chmod +x local_cronjobs/backup_postgres.sh
   ```

4. Test the backup manually:
   ```bash
   ./local_cronjobs/backup_postgres.sh
   ```

5. Set up the cronjob:
   ```bash
   crontab -e
   # Add: 0 1 * * 0 /Users/nicolaitanghoj/dev/infra_backups/local_cronjobs/backup_postgres.sh
   ```

## Files

| File | Description |
|------|-------------|
| `dump_psql_backup.sh` | Main backup script (dump, sync, rotate) |
| `local_cronjobs/backup_postgres.sh` | Cronjob wrapper (loads env, runs backup) |
| `.default.env` | Default configuration (tracked in git) |
| `.development.env` | Local overrides (gitignored) |
| `.envrc` | direnv config |
| `cronjob.example` | Cron schedule example |

## Configuration

### .default.env (defaults)
```bash
DB_USER="nicolaivinther"
DB_LIST="pinnacle_odds,basketball_stats,icehockey_stats,multisport_stats"
BACKUP_DIR="/tmp/pg_backups"
REMOTE_PATH="/media/antimac/Cloud"
KEEP_BACKUPS="2"
```

### .development.env (local overrides)
```bash
REMOTE_USER="nicolai"
REMOTE_HOST="192.168.11.3"
```

## Backup Schedule

Weekly on Sunday at 01:00 AM

Logs: `/tmp/pg_backups/pg_backup.log`

## Retention Policy

- **Local**: 2 most recent backups per database
- **Remote**: 2 most recent backups per database

## Restoring a Backup

```bash
# Download backup from remote
scp user@remote:/media/antimac/Cloud/database_name_20250101_0100.dump.gz .

# Decompress and restore
gunzip -c database_name_20250101_0100.dump.gz | pg_restore -U nicolaivinther -d database_name
```

## WireGuard Auto-Start

WireGuard is configured to start on boot via LaunchDaemon:
```
/Library/LaunchDaemons/com.wireguard.Nicolai_MacMini.plist
```

Check status: `sudo wg show`

## Author

Nicolai Tanghoj - 2025