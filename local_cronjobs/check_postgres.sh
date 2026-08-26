#!/usr/bin/env bash
# PostgreSQL availability check — runs from cron every 5 minutes.
#
# Exists because PostgreSQL cannot auto-start at boot (TCC blocks launchd from
# /Volumes/MiniData, Linear BAS-179): after an unattended reboot the database
# stays down until someone runs ~/start-pg.sh, and every cron pipeline fails
# silently meanwhile. The 2026-07-31 outage went hours unnoticed.
#
# pg_isready over TCP needs no volume access, so TCC does not apply here.
# Deliberately NOT wrapped in run_job.sh: that records into postgres, which is
# the thing being checked.
#
# Alerts (Sentry, same DSN as the backups):
#   - "down" once when the check first fails, then a reminder every hour;
#   - "recovered" once when it comes back.
# State lives in ~/.cron_monitor/postgres_check.state (survives reboot — that
# is the whole point, /tmp does not).

set -uo pipefail

export PATH="/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /Users/nicolaitanghoj/dev/infra_backups

set -a
[ -f .default.env ] && source .default.env
[ -f .development.env ] && source .development.env
set +a

STATE_DIR="/Users/nicolaitanghoj/.cron_monitor"
STATE_FILE="${STATE_DIR}/postgres_check.state"
LOG_FILE="${STATE_DIR}/postgres_check.log"
REMIND_SECS=3600
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Fire-and-forget Sentry event. Mirrors alert() in dump_psql_backup.sh.
alert() {
    local level="$1" summary="$2" detail="${3:-}"
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
        --arg level "$level" \
        --arg msg "$summary" \
        --arg detail "$detail" \
        --arg env "${SENTRY_ENVIRONMENT:-production}" \
        --arg host "$(hostname)" \
        '{event_id: $event_id, timestamp: $ts, platform: "other",
          level: $level, logger: "pg_check", server_name: $host,
          environment: $env,
          message: {formatted: $msg},
          tags: {job: "pg_check"},
          extra: {detail: $detail}}' 2>/dev/null) || return 0
    curl -sS --max-time 15 -X POST \
        "https://${host}/api/${project}/store/" \
        -H "Content-Type: application/json" \
        -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_client=pg_check/1.0, sentry_key=${key}" \
        -d "$payload" >/dev/null 2>&1 \
        && log "Sentry alert sent: ${summary}" \
        || log "WARNING: could not reach Sentry to report: ${summary}"
    return 0
}

now=$(date +%s)
prev_status="up"; down_since=0; last_alert=0
[ -f "$STATE_FILE" ] && source "$STATE_FILE"

save_state() {
    printf 'prev_status=%s\ndown_since=%s\nlast_alert=%s\n' "$1" "$2" "$3" > "${STATE_FILE}.tmp" \
        && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

output=$(pg_isready -h 127.0.0.1 -p 5432 -t 10 2>&1)
if [ $? -eq 0 ]; then
    if [ "$prev_status" = "down" ]; then
        mins=$(( (now - down_since) / 60 ))
        log "RECOVERED after ${mins} min"
        alert info "PostgreSQL recovered on $(hostname) after ${mins} min" "$output"
    fi
    save_state up 0 0
    exit 0
fi

uptime_secs=$(( now - $(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/') ))
detail="pg_isready: ${output} | uptime=$((uptime_secs / 60))min | fix: run ~/start-pg.sh on the mini (BAS-179)"

if [ "$prev_status" = "up" ]; then
    log "DOWN — ${output}"
    alert error "PostgreSQL DOWN on $(hostname) — not accepting connections" "$detail"
    save_state down "$now" "$now"
elif [ $(( now - last_alert )) -ge "$REMIND_SECS" ]; then
    mins=$(( (now - down_since) / 60 ))
    log "still down (${mins} min)"
    alert error "PostgreSQL still DOWN on $(hostname) — ${mins} min" "$detail"
    save_state down "$down_since" "$now"
else
    save_state down "$down_since" "$last_alert"
fi
exit 1
