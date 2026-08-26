#!/bin/bash
# Recover PostgreSQL after the LaunchDaemon TCC hang.
#
# Run WITHOUT sudo:   ./start-pg.sh
# It sudo's only the two steps that need root; pg_ctl must run as your own user
# because postgres refuses to start as root.
#
# Why: a launchd-spawned process gets "Operation not permitted" (EPERM) reading
# /Volumes/MiniData — macOS privacy protection, which launchd jobs do not
# inherit. An interactive session has the grant, so starting from here works.

set -uo pipefail

PGBIN=/opt/homebrew/opt/postgresql@16/bin
DATA=/Volumes/MiniData/postgres_data
LOG=/Users/nicolaitanghoj/Library/Logs/postgresql16.log

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: do NOT run this with sudo — postgres cannot start as root." >&2
    echo "       Run it as: ./start-pg.sh" >&2
    exit 1
fi

echo "=== 1. unloading the stuck LaunchDaemon (needs your password) ==="
sudo launchctl bootout system/com.nicolai.postgresql16 2>/dev/null \
    && echo "  unloaded" || echo "  (was not loaded — fine)"

echo "=== 2. removing the plist so it cannot hang again at next boot ==="
sudo rm -f /Library/LaunchDaemons/com.nicolai.postgresql16.plist
echo "  removed (it is safe in git)"

echo "=== 3. checking nothing is already running ==="
if "$PGBIN/pg_ctl" -D "$DATA" status >/dev/null 2>&1; then
    echo "  a postmaster is already running — nothing to do"
    "$PGBIN/pg_ctl" -D "$DATA" status
    exit 0
fi
pkill -f "postgres -D $DATA" 2>/dev/null && echo "  cleared a stuck postgres process"

echo "=== 4. starting PostgreSQL ==="
"$PGBIN/pg_ctl" -D "$DATA" -l "$LOG" start
echo

echo "=== 5. waiting for it to accept connections (WAL recovery can take minutes) ==="
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
