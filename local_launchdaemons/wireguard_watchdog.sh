#!/bin/bash
# WireGuard watchdog — runs as root from com.wireguard.watchdog.plist.
#
# Why this exists: the boot daemon (com.wireguard.Nicolai_MacMini.plist) has
# RunAtLoad only, and `wg-quick up` exits once the interface is configured, so
# KeepAlive cannot help. That leaves a gap: if the tunnel dies while the machine
# is running, nothing restores it until the next reboot. In 2026-07 the tunnel
# went down and three weekly backups failed silently.
#
# Deliberately conservative: it will not bounce a healthy tunnel just because
# the far-side host is unreachable, since Marcus' server being down is not a
# reason to tear down our end. A ping failure has to persist across two runs
# (~20 min) before the tunnel is recycled.

set -uo pipefail

IFACE="Nicolai_MacMini"
PROBE_HOST="192.168.11.3"
WG_QUICK="/opt/homebrew/bin/wg-quick"
WG="/opt/homebrew/bin/wg"
LOG="/var/log/wireguard-watchdog.log"
STATE="/var/run/wireguard-watchdog.fails"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

bounce() {
    log "RECOVERY: recycling tunnel ($1)"
    "$WG_QUICK" down "$IFACE" >>"$LOG" 2>&1 || log "  (down failed or interface absent — continuing)"
    if "$WG_QUICK" up "$IFACE" >>"$LOG" 2>&1; then
        log "  tunnel back up"
        echo 0 > "$STATE"
    else
        log "  ERROR: wg-quick up FAILED"
    fi
    # Keep the log bounded.
    tail -n 1000 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
    exit 0
}

# --- 1. Does the interface exist at all? ---
# wg reports the kernel device name (utunN), not the config name, so presence
# of any interface plus the route check below is what we key off.
IFACES=$("$WG" show interfaces 2>/dev/null || true)
if [ -z "$IFACES" ]; then
    bounce "no WireGuard interface present"
fi

# --- 2. Is the split-tunnel route for the backup host still on a wg device? ---
ROUTE_IF=$(route -n get "$PROBE_HOST" 2>/dev/null | awk '/interface:/ {print $2}')
if [ -z "$ROUTE_IF" ] || [ "${ROUTE_IF#utun}" = "$ROUTE_IF" ]; then
    bounce "route to ${PROBE_HOST} is via '${ROUTE_IF:-none}', not a tunnel device"
fi

# --- 3. Can we actually reach the backup server? ---
if ping -c 2 -W 3000 "$PROBE_HOST" >/dev/null 2>&1; then
    [ "$(cat "$STATE" 2>/dev/null || echo 0)" != "0" ] && log "OK: ${PROBE_HOST} reachable again"
    echo 0 > "$STATE"
    exit 0
fi

FAILS=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$FAILS" > "$STATE"
log "WARNING: ${PROBE_HOST} unreachable (consecutive failures: ${FAILS}) — interface and route look fine"

if [ "$FAILS" -ge 2 ]; then
    bounce "unreachable for ${FAILS} consecutive checks"
fi

exit 0
