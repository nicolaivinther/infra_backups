#!/bin/bash
# PostgreSQL launcher — runs as nicolaitanghoj from com.nicolai.postgresql16.plist.
#
# Why this exists: the cluster's data directory lives on the external MiniData
# volume, and Homebrew's stock service points at the internal default data dir
# (/opt/homebrew/var/postgresql@16) — which is why `brew services start` was
# never an option and every reboot needed a manual
# `pg_ctl -D /Volumes/MiniData/postgres_data start`. This script:
#
#   1. waits for /Volumes/MiniData to mount (launchd starts us before external
#      volumes are necessarily up),
#   2. defers to an already-running postmaster instead of fighting over the
#      lock file (covers the manual-start era and the install-time handover),
#   3. runs postgres in the foreground so launchd supervises it and restarts
#      it after a crash (KeepAlive SuccessfulExit=false: crashes restart,
#      a clean `pg_ctl stop` stays stopped until reboot or
#      `sudo launchctl kickstart system/com.nicolai.postgresql16`).
#
# launchd sends SIGTERM at shutdown, which postgres treats as a "smart"
# shutdown that waits forever for idle clients. We trap it and forward SIGINT
# (fast shutdown) so the cluster closes cleanly instead of being SIGKILLed.

set -uo pipefail

DATA_DIR="/Volumes/MiniData/postgres_data"
PG_BIN="/opt/homebrew/opt/postgresql@16/bin"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Wait up to 5 minutes for the external volume.
for _ in $(seq 1 60); do
    [ -d "$DATA_DIR" ] && break
    sleep 5
done
if [ ! -d "$DATA_DIR" ]; then
    log "ERROR: $DATA_DIR not present after 5 min — is MiniData mounted? Exiting; launchd will retry."
    exit 1
fi

# Defer to an existing postmaster (e.g. one started manually with pg_ctl).
# When it stops, we take over within 30s.
if "$PG_BIN/pg_ctl" -D "$DATA_DIR" status >/dev/null 2>&1; then
    log "postmaster already running for $DATA_DIR — waiting for it to stop before taking over"
    while "$PG_BIN/pg_ctl" -D "$DATA_DIR" status >/dev/null 2>&1; do
        sleep 30
    done
    log "existing postmaster stopped — taking over"
fi

"$PG_BIN/postgres" -D "$DATA_DIR" &
PG_PID=$!
trap 'kill -INT "$PG_PID" 2>/dev/null' TERM INT

# `wait` returns early when a trapped signal arrives; loop until the child is
# actually gone so the trap can do its fast-shutdown forwarding.
STATUS=0
while :; do
    wait "$PG_PID"
    STATUS=$?
    kill -0 "$PG_PID" 2>/dev/null || break
done
log "postgres exited with status $STATUS"
exit "$STATUS"
