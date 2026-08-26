#!/bin/bash
# PostgreSQL boot launcher — runs as nicolaitanghoj from com.nicolai.postgresql16.plist.
#
# It does NOT touch the data directory itself: macOS TCC denies launchd-spawned
# processes access to /Volumes/MiniData (open() blocks, see CLAUDE.md). Instead
# it starts postgres through `ssh localhost` with a key restricted to the
# forced command pg_autostart_cmd.sh. sshd holds Full Disk Access, so the
# postmaster it spawns can read the volume. No GUI grant, no Cellar-path pin.
#
# One-shot at boot with retries; launchd does not supervise the postmaster
# (pg_ctl detaches it). check_postgres.sh alerts if it is ever down.

set -uo pipefail

DATA_DIR="/Volumes/MiniData/postgres_data"
KEY="/Users/nicolaitanghoj/.ssh/pg_autostart_ed25519"
KNOWN_HOSTS="/Users/nicolaitanghoj/.ssh/known_hosts"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] launcher: $*"; }

# Wait up to 5 minutes for the external volume. stat/-d is metadata and is
# allowed by TCC; only content reads are denied.
for _ in $(seq 1 60); do
    [ -d "$DATA_DIR" ] && break
    sleep 5
done
if [ ! -d "$DATA_DIR" ]; then
    log "ERROR: $DATA_DIR not present after 5 min — is MiniData mounted?"
    exit 1
fi

# Wait up to 2 minutes for sshd to accept connections.
for _ in $(seq 1 24); do
    nc -z -w 2 127.0.0.1 22 >/dev/null 2>&1 && break
    sleep 5
done

for attempt in 1 2 3 4 5; do
    if /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$KNOWN_HOSTS" \
            -i "$KEY" 127.0.0.1; then
        log "postgres started (attempt $attempt)"
        exit 0
    fi
    log "attempt $attempt failed; retrying in 30s"
    sleep 30
done
log "ERROR: could not start postgres via ssh after 5 attempts"
exit 1
