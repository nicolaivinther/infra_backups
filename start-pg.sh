#!/bin/bash
# Manual PostgreSQL start — fallback if the boot daemon did not bring it up
# (check ~/Library/Logs/postgresql16.log first).
#
# Run WITHOUT sudo:   ./start-pg.sh   (postgres refuses to start as root)
#
# An interactive/SSH session holds Full Disk Access on /Volumes/MiniData, so
# starting from here always works. See CLAUDE.md "PostgreSQL auto-start".

set -uo pipefail

PGBIN=/opt/homebrew/opt/postgresql@16/bin
DATA=/Volumes/MiniData/postgres_data
LOG=/Users/nicolaitanghoj/Library/Logs/postgresql16.log

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: do NOT run this with sudo — postgres cannot start as root." >&2
    echo "       Run it as: ./start-pg.sh" >&2
    exit 1
fi

echo "=== 1. checking nothing is already running ==="
if "$PGBIN/pg_ctl" -D "$DATA" status >/dev/null 2>&1; then
    echo "  a postmaster is already running — nothing to do"
    "$PGBIN/pg_ctl" -D "$DATA" status
    exit 0
fi
pkill -f "postgres -D $DATA" 2>/dev/null && echo "  cleared a stuck postgres process"

echo "=== 2. starting PostgreSQL ==="
"$PGBIN/pg_ctl" -D "$DATA" -l "$LOG" start
echo

echo "=== 3. waiting for it to accept connections (WAL recovery can take minutes) ==="
for i in $(seq 1 60); do
    if "$PGBIN/pg_isready" -q 2>/dev/null; then
        echo "  READY after ~$((i * 5))s"
        "$PGBIN/psql" -U nicolaivinther -d postgres -X -t -c "select 'connections OK';" 2>&1 | head -2
        echo
        echo "=== recent log ==="
        tail -8 "$LOG"
        exit 0
    fi
    sleep 5
done

echo "  STILL NOT READY after 5 min — check the log:"
tail -20 "$LOG"
exit 1
