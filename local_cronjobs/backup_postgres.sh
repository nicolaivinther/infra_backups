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

# The WireGuard tunnel is managed by the LaunchDaemons and stays up 24/7 —
# this script must NOT bring it up or down (see local_launchdaemons/). It also
# cannot: cron has no tty for sudo, and tearing the tunnel down would fight the
# watchdog. dump_psql_backup.sh's preflight fails fast with a Sentry alert if
# the tunnel is down.

./dump_psql_backup.sh
