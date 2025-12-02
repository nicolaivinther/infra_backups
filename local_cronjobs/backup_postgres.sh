#!/usr/bin/env bash
set -euo pipefail

cd /Users/nicolaitanghoj/dev/infra_backups

# Load environment variables
set -a
[ -f .default.env ] && source .default.env
[ -f .development.env ] && source .development.env
set +a

# Start WireGuard
sudo wg-quick up Nicolai_MacMini

# Run backup (ensure WireGuard is stopped even if backup fails)
./dump_psql_backup.sh || BACKUP_FAILED=1

# Stop WireGuard
sudo wg-quick down Nicolai_MacMini

# Exit with backup status
exit ${BACKUP_FAILED:-0}
