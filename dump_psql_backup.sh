#!/bin/bash
# PostgreSQL multi-database backup and sync to Marcus' server
# Author: Nicolai Tanghoj — 2025
#
# Flow per database: dump -> verify -> transfer -> verify remote -> rotate.
# Rotation only ever runs after the new dump has been verified, so a corrupt
# or truncated dump can never evict a known-good copy.

set -euo pipefail

# === DEFAULTS (can be overridden via environment) ===
BACKUP_DIR="${BACKUP_DIR:-/Users/nicolaitanghoj/pg_backups}"
LOG_FILE="${LOG_FILE:-${BACKUP_DIR}/pg_backup.log}"
STATUS_FILE="${STATUS_FILE:-${BACKUP_DIR}/last_run_status}"
KEEP_LOCAL_BACKUPS="${KEEP_LOCAL_BACKUPS:-1}"
KEEP_REMOTE_BACKUPS="${KEEP_REMOTE_BACKUPS:-12}"
# Peak local usage is two full sets (~40GB) because the previous dump is only
# removed after the new one has shipped.
MIN_FREE_GB="${MIN_FREE_GB:-45}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=15}"

mkdir -p "$BACKUP_DIR"

RUN_START=$(date +%s)
CURRENT_STAGE="startup"
CURRENT_DB="-"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Fire-and-forget Sentry event. Never allowed to fail the backup.
alert() {
    local summary="$1"
    local detail="${2:-}"

    if [ -z "${SENTRY_DSN:-}" ]; then
        log "alerting disabled (no SENTRY_DSN) — would have sent: ${summary}"
        return 0
    fi

    local rest key hostpath host project payload event_id
    rest="${SENTRY_DSN#*://}"
    key="${rest%%@*}"
    hostpath="${rest#*@}"
    host="${hostpath%%/*}"
    project="${hostpath##*/}"
    event_id=$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')

    payload=$(jq -n \
        --arg event_id "$event_id" \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%S')" \
        --arg msg "$summary" \
        --arg detail "$detail" \
        --arg env "${SENTRY_ENVIRONMENT:-production}" \
        --arg db "$CURRENT_DB" \
        --arg stage "$CURRENT_STAGE" \
        --arg host "$(hostname)" \
        '{event_id: $event_id, timestamp: $ts, platform: "other",
          level: "error", logger: "pg_backup", server_name: $host,
          environment: $env,
          message: {formatted: $msg},
          tags: {job: "pg_backup", database: $db, stage: $stage},
          extra: {detail: $detail}}' 2>/dev/null) || return 0

    curl -sS --max-time 15 -X POST \
        "https://${host}/api/${project}/store/" \
        -H "Content-Type: application/json" \
        -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_client=pg_backup/1.0, sentry_key=${key}" \
        -d "$payload" >/dev/null 2>&1 \
        && log "Sentry alert sent: ${summary}" \
        || log "WARNING: could not reach Sentry to report: ${summary}"
    return 0
}

on_error() {
    local exit_code=$?
    local line="$1"
    log "FAILED at line ${line} (exit ${exit_code}) during stage '${CURRENT_STAGE}' for database '${CURRENT_DB}'"
    echo "FAIL $(date '+%Y-%m-%d %H:%M:%S') stage=${CURRENT_STAGE} db=${CURRENT_DB} exit=${exit_code}" > "$STATUS_FILE"
    alert "pg_backup FAILED: ${CURRENT_DB} during ${CURRENT_STAGE}" \
          "exit=${exit_code} line=${line} host=$(hostname) log=${LOG_FILE}"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

fail() {
    log "ERROR: $*"
    return 1
}

human_secs() {
    local s=$1
    printf '%dm%02ds' $((s / 60)) $((s % 60))
}

# ============================================================
# PREFLIGHT — fail in seconds rather than after dumping ~18GB
# ============================================================
CURRENT_STAGE="preflight"
log "=== Preflight checks ==="

for var in DB_USER DB_LIST REMOTE_USER REMOTE_HOST REMOTE_PATH; do
    [ -n "${!var:-}" ] || fail "required variable ${var} is not set"
done

command -v pg_dump >/dev/null || fail "pg_dump not found on PATH (${PATH})"

# Local free space
AVAIL_GB=$(df -g "$BACKUP_DIR" | awk 'NR==2 {print $4}')
if [ "$AVAIL_GB" -lt "$MIN_FREE_GB" ]; then
    fail "only ${AVAIL_GB}GB free at ${BACKUP_DIR}, need ${MIN_FREE_GB}GB"
fi
log "Local free space: ${AVAIL_GB}GB (need ${MIN_FREE_GB}GB) — OK"

# Tunnel / SSH reachability. This is the check that was missing: the 2026-07
# outage dumped 18GB before discovering the VPN was down.
if ! ssh $SSH_OPTS "${REMOTE_USER}@${REMOTE_HOST}" true 2>/dev/null; then
    fail "cannot SSH to ${REMOTE_USER}@${REMOTE_HOST} — is the WireGuard tunnel up? (sudo wg show)"
fi
log "SSH to ${REMOTE_USER}@${REMOTE_HOST} — OK"

# Remote path must exist, be writable, and be a real mount (not an empty
# directory on the root filesystem after a rebuild).
REMOTE_PREFLIGHT=$(ssh $SSH_OPTS "${REMOTE_USER}@${REMOTE_HOST}" "
    set -e
    [ -d '${REMOTE_PATH}' ] || { echo 'MISSING_DIR'; exit 1; }
    [ -w '${REMOTE_PATH}' ] || { echo 'NOT_WRITABLE'; exit 1; }
    mountpoint -q \"\$(df --output=target '${REMOTE_PATH}' | tail -1)\" || { echo 'NOT_A_MOUNT'; exit 1; }
    df -BG --output=avail '${REMOTE_PATH}' | tail -1 | tr -dc '0-9'
" 2>&1) || fail "remote preflight failed: ${REMOTE_PREFLIGHT}"
log "Remote ${REMOTE_PATH} is a writable mount with ${REMOTE_PREFLIGHT}GB free — OK"

log "=== Preflight passed ==="

# ============================================================
# BACKUP
# ============================================================
IFS=',' read -ra DB_ARRAY <<< "$DB_LIST"

log "Starting multi-database backup (${#DB_ARRAY[@]} databases, keep ${KEEP_LOCAL_BACKUPS} local / ${KEEP_REMOTE_BACKUPS} remote)"

for DB_NAME in "${DB_ARRAY[@]}"; do
    CURRENT_DB="$DB_NAME"
    DB_START=$(date +%s)
    DATE_STR=$(date +%Y%m%d_%H%M)
    DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_${DATE_STR}.dump.gz"

    # --- dump ---
    CURRENT_STAGE="dump"
    log "[${DB_NAME}] Dumping..."
    T0=$(date +%s)
    pg_dump -U "$DB_USER" -Fc "$DB_NAME" | gzip > "$DUMP_FILE"
    DUMP_SECS=$(( $(date +%s) - T0 ))
    DUMP_BYTES=$(stat -f %z "$DUMP_FILE")
    log "[${DB_NAME}] Dumped $(( DUMP_BYTES / 1048576 ))MB in $(human_secs $DUMP_SECS)"

    # --- verify ---
    # gzip -t catches truncation and corruption (it validates the whole stream
    # and its CRC). pg_restore --list only reads the archive header, so it is
    # a structural sanity check, NOT a truncation check — both are needed.
    CURRENT_STAGE="verify_local"
    log "[${DB_NAME}] Verifying dump integrity..."
    T0=$(date +%s)
    gzip -t "$DUMP_FILE" || fail "[${DB_NAME}] gzip integrity check failed — dump is corrupt or truncated"
    # pipefail must be off for this one pipeline: pg_restore --list reads only
    # the archive header and exits 0, which kills gunzip with SIGPIPE. Under
    # pipefail that non-zero gunzip status would fail a perfectly good dump.
    ( set +o pipefail; gunzip -c "$DUMP_FILE" | pg_restore --list >/dev/null 2>&1 ) \
        || fail "[${DB_NAME}] pg_restore could not read the archive TOC"
    log "[${DB_NAME}] Verified in $(human_secs $(( $(date +%s) - T0 )))"

    # --- transfer ---
    CURRENT_STAGE="transfer"
    log "[${DB_NAME}] Transferring to ${REMOTE_HOST}..."
    T0=$(date +%s)
    rsync -az --partial --timeout=600 -e "ssh $SSH_OPTS" \
        "$DUMP_FILE" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"
    XFER_SECS=$(( $(date +%s) - T0 ))
    log "[${DB_NAME}] Transferred in $(human_secs $XFER_SECS) ($(( DUMP_BYTES / 1048576 / (XFER_SECS > 0 ? XFER_SECS : 1) ))MB/s)"

    # --- verify remote copy matches byte-for-byte in size ---
    CURRENT_STAGE="verify_remote"
    REMOTE_BYTES=$(ssh $SSH_OPTS "${REMOTE_USER}@${REMOTE_HOST}" \
        "stat -c %s '${REMOTE_PATH}/$(basename "$DUMP_FILE")'" 2>/dev/null) \
        || fail "[${DB_NAME}] could not stat the transferred file on the remote"
    if [ "$REMOTE_BYTES" != "$DUMP_BYTES" ]; then
        fail "[${DB_NAME}] size mismatch: local ${DUMP_BYTES} vs remote ${REMOTE_BYTES}"
    fi
    log "[${DB_NAME}] Remote copy verified (${REMOTE_BYTES} bytes)"

    # --- rotate (only reached once the new copy is verified on both ends) ---
    CURRENT_STAGE="rotate_local"
    ( cd "$BACKUP_DIR" && ls -t "${DB_NAME}"_*.dump.gz 2>/dev/null \
        | tail -n +$((KEEP_LOCAL_BACKUPS + 1)) | xargs -r rm -- ) || true
    log "[${DB_NAME}] Local rotation: kept ${KEEP_LOCAL_BACKUPS} newest"

    CURRENT_STAGE="rotate_remote"
    ssh $SSH_OPTS "${REMOTE_USER}@${REMOTE_HOST}" \
        "cd '${REMOTE_PATH}' && ls -t ${DB_NAME}_*.dump.gz 2>/dev/null | tail -n +$((KEEP_REMOTE_BACKUPS + 1)) | xargs -r rm --" || true
    log "[${DB_NAME}] Remote rotation: kept ${KEEP_REMOTE_BACKUPS} newest"

    log "[${DB_NAME}] Done in $(human_secs $(( $(date +%s) - DB_START )))"
done

CURRENT_STAGE="complete"
CURRENT_DB="-"
TOTAL_SECS=$(( $(date +%s) - RUN_START ))
log "All database backups completed successfully in $(human_secs $TOTAL_SECS)"
echo "OK $(date '+%Y-%m-%d %H:%M:%S') duration=$(human_secs $TOTAL_SECS)" > "$STATUS_FILE"

# Keep the log bounded without losing the reboot-surviving history.
tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
