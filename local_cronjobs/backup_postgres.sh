#!/usr/bin/env bash
set -euo pipefail

# cron runs with a minimal PATH that lacks Homebrew's pg_dump; set it explicitly.
export PATH="/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cd /Users/nicolaitanghoj/dev/infra_backups

# Load environment variables
set -a
[ -f .default.env ] && source .default.env
[ -f .development.env ] && source .development.env
set +a

./dump_psql_backup.sh
