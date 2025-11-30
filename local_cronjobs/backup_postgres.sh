#!/usr/bin/env bash
set -euo pipefail

cd /Users/nicolaitanghoj/dev/infra_backups

# Load environment variables
set -a
[ -f .default.env ] && source .default.env
[ -f .development.env ] && source .development.env
set +a

./dump_psql_backup.sh
