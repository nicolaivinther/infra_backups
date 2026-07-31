#!/usr/bin/env bash
# Cron wrapper. Takes an optional profile name:
#
#   ./local_cronjobs/backup_postgres.sh daily    # small operational DBs, nightly
#   ./local_cronjobs/backup_postgres.sh weekly   # pinnacle_odds, weekly
#   ./local_cronjobs/backup_postgres.sh          # everything in .default.env
#
# A profile is just `.<name>.env`, sourced last so it wins on DB_LIST and
# retention. Profiles cover disjoint sets of databases, and rotation globs are
# per-database (`<db>_*.dump.gz`), so the two schedules never rotate each
# other's dumps despite sharing one remote directory.

set -euo pipefail

PROFILE="${1:-}"

# cron runs with a minimal PATH that lacks Homebrew's pg_dump; set it explicitly.
export PATH="/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cd /Users/nicolaitanghoj/dev/infra_backups

# Load environment variables
set -a
[ -f .default.env ] && source .default.env
[ -f .development.env ] && source .development.env
if [ -n "$PROFILE" ]; then
    if [ ! -f ".${PROFILE}.env" ]; then
        echo "ERROR: unknown profile '${PROFILE}' (no .${PROFILE}.env in $(pwd))" >&2
        exit 1
    fi
    source ".${PROFILE}.env"
fi
set +a

export BACKUP_PROFILE="$PROFILE"

# The WireGuard tunnel is managed by the LaunchDaemons and stays up 24/7 —
# this script must NOT bring it up or down (see local_launchdaemons/). It also
# cannot: cron has no tty for sudo, and tearing the tunnel down would fight the
# watchdog. dump_psql_backup.sh's preflight fails fast with a Sentry alert if
# the tunnel is down.

./dump_psql_backup.sh
