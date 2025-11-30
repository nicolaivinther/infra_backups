# PostgreSQL Off-Site Backup System

Automated PostgreSQL database dumps synced to a remote server via WireGuard VPN.

## Overview

This repository provides a reliable off-machine backup solution for PostgreSQL databases. Backups are:
- Dumped nightly using `pg_dump`
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
   ssh-keygen -t ed25519 -C "backup@macmini"
   ssh-copy-id marcus@10.0.0.2
   ```

2. **WireGuard VPN** connection active

3. **PostgreSQL** with `pg_dump` available

4. **rsync** installed on both machines

## Installation

1. Clone this repository:
   ```bash
   git clone <repo-url> ~/infra-backups
   cd ~/infra-backups
   ```

2. Copy and configure the environment file:
   ```bash
   cp config.env.example config.env
   # Edit config.env with your settings
   ```

3. Make the backup script executable:
   ```bash
   chmod +x backup.sh
   ```

4. Test the backup manually:
   ```bash
   ./backup.sh
   ```

5. Set up the cronjob:
   ```bash
   crontab -e
   # Add the line from cronjob.example
   ```

## Files

| File | Description |
|------|-------------|
| `backup.sh` | Main backup script |
| `config.env.example` | Configuration template |
| `cronjob.example` | Cron schedule example |

## Configuration

Edit `config.env` with your settings:

```bash
DB_USER="your_postgres_user"
DB_LIST=("db1" "db2" "db3")
REMOTE_USER="marcus"
REMOTE_HOST="10.0.0.2"
REMOTE_PATH="/media/antimac/Cloud"
```

## Backup Schedule

Default: Daily at 01:00 AM

Logs are written to `/tmp/pg_backups/pg_backup.log`

## Retention Policy

- **Local**: 2 most recent backups per database
- **Remote**: 2 most recent backups per database

## Restoring a Backup

```bash
# Download backup from remote
scp marcus@10.0.0.2:/media/antimac/Cloud/database_name_20250101_0100.dump.gz .

# Decompress and restore
gunzip -c database_name_20250101_0100.dump.gz | pg_restore -U nicolaivinther -d database_name
```

## Future Improvements

- [ ] Failover scraping logic (detect Mac-mini-down, activate scraper on Marcus' server)
- [ ] Delta sync handling
- [ ] Monitoring/alerting on backup failures

## Author

Nicolai Tanghoj - 2025
