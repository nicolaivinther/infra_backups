#!/bin/bash
# PostgreSQL multi-database backup and sync to Marcus' server
# Author: Nicolai Tanghoj — 2025

set -euo pipefail

# === DEFAULTS (can be overridden via environment) ===
BACKUP_DIR="${BACKUP_DIR:-/tmp/pg_backups}"
LOG_FILE="${LOG_FILE:-${BACKUP_DIR}/pg_backup.log}"
KEEP_BACKUPS="${KEEP_BACKUPS:-2}"

# Convert comma-separated DB_LIST to array
IFS=',' read -ra DB_ARRAY <<< "$DB_LIST"

# === PREPARE BACKUP DIRECTORY ===
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting multi-database backup..." | tee -a "$LOG_FILE"

for DB_NAME in "${DB_ARRAY[@]}"; do
    DATE_STR=$(date +%Y%m%d_%H%M)
    DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_${DATE_STR}.dump.gz"

    echo "[$(date)] Dumping database: $DB_NAME" | tee -a "$LOG_FILE"
    pg_dump -U "$DB_USER" -Fc "$DB_NAME" | gzip > "$DUMP_FILE"
    echo "[$(date)] Created dump: $DUMP_FILE" | tee -a "$LOG_FILE"

    # === TRANSFER TO MARCUS ===
    rsync -avz --progress "$DUMP_FILE" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"
    echo "[$(date)] Transferred ${DB_NAME} backup to Marcus' server." | tee -a "$LOG_FILE"

    # === CLEAN UP OLD LOCAL BACKUPS (KEEP N MOST RECENT) ===
    cd "$BACKUP_DIR"
    ls -t ${DB_NAME}_*.dump.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -- 2>/dev/null || true
    echo "[$(date)] Local cleanup for ${DB_NAME}: kept ${KEEP_BACKUPS} newest." | tee -a "$LOG_FILE"

    # === CLEAN UP OLD REMOTE BACKUPS (KEEP N MOST RECENT) ===
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "cd ${REMOTE_PATH} && ls -t ${DB_NAME}_*.dump.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -- 2>/dev/null || true"
    echo "[$(date)] Remote cleanup for ${DB_NAME}: kept ${KEEP_BACKUPS} newest." | tee -a "$LOG_FILE"

done

echo "[$(date)] All database backups completed successfully." | tee -a "$LOG_FILE"
