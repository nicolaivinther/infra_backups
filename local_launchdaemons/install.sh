#!/bin/bash
# Installs the WireGuard and PostgreSQL LaunchDaemons. Run with sudo:
#
#   sudo ./local_launchdaemons/install.sh
#
# Idempotent — safe to re-run after pulling changes.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run with sudo" >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC=/usr/local/libexec
DAEMONS=/Library/LaunchDaemons

echo "=== installing watchdog script ==="
mkdir -p "$LIBEXEC"
install -o root -g wheel -m 755 "${SRC}/wireguard_watchdog.sh" "${LIBEXEC}/wireguard_watchdog.sh"
echo "  ${LIBEXEC}/wireguard_watchdog.sh"

echo "=== installing plists ==="
for label in com.wireguard.Nicolai_MacMini com.wireguard.watchdog; do
    install -o root -g wheel -m 644 "${SRC}/${label}.plist" "${DAEMONS}/${label}.plist"
    plutil -lint "${DAEMONS}/${label}.plist"
done

echo "=== securing tunnel config ==="
CONF=/usr/local/etc/wireguard/Nicolai_MacMini.conf
if [ -f "$CONF" ]; then
    chown root:wheel "$CONF"
    chmod 600 "$CONF"
    echo "  ${CONF} -> root:wheel 0600"
else
    echo "  WARNING: ${CONF} not found — the tunnel config is not in this repo (it holds the private key)"
fi

echo "=== reloading daemons ==="

# The boot daemon has RunAtLoad, so bootstrapping it runs `wg-quick up`. If the
# tunnel is already healthy that is at best a no-op error, and re-upping mid
# backup would break an in-flight transfer. So leave a healthy tunnel alone —
# the corrected plist takes effect at the next boot either way.
TUNNEL_HEALTHY=no
if /opt/homebrew/bin/wg show 2>/dev/null | grep -q 'latest handshake'; then
    TUNNEL_HEALTHY=yes
fi

if [ "$TUNNEL_HEALTHY" = yes ]; then
    echo "  com.wireguard.Nicolai_MacMini: tunnel already up — plist installed, active at next boot"
else
    launchctl bootout system/com.wireguard.Nicolai_MacMini 2>/dev/null || true
    launchctl bootstrap system "${DAEMONS}/com.wireguard.Nicolai_MacMini.plist"
    echo "  com.wireguard.Nicolai_MacMini loaded (tunnel was down)"
fi

# The watchdog is always safe to (re)load: it inspects before it acts.
launchctl bootout system/com.wireguard.watchdog 2>/dev/null || true
launchctl bootstrap system "${DAEMONS}/com.wireguard.watchdog.plist"
echo "  com.wireguard.watchdog loaded (runs every 600s)"

echo "=== postgres daemon ==="
# The postgres daemon is NOT installed by default. macOS TCC denies a
# launchd-spawned postgres access to /Volumes/MiniData: the postmaster blocks
# in open() on postgresql.conf, and a stuck daemon child can wedge the *live*
# postmaster's lock-file recheck (both happened on 2026-07-31; the daemon was
# reinstalled by accident on 2026-08-25 and spent a day respawning hung
# processes). Until the Cellar binaries hold Full Disk Access — see Linear
# BAS-179 and CLAUDE.md "PostgreSQL auto-start" — it must stay uninstalled.
if [ "${INSTALL_POSTGRES_DAEMON:-0}" = "1" ]; then
    install -o root -g wheel -m 755 "${SRC}/start_postgres_minidata.sh" "${LIBEXEC}/start_postgres_minidata.sh"
    install -o root -g wheel -m 644 "${SRC}/com.nicolai.postgresql16.plist" "${DAEMONS}/com.nicolai.postgresql16.plist"
    plutil -lint "${DAEMONS}/com.nicolai.postgresql16.plist"

    # Loading while a manually-started postmaster is running is safe: the launcher
    # defers to it and only takes over once it stops (see start_postgres_minidata.sh).
    # If already loaded, leave it alone — a bootout would restart a live database.
    if launchctl print system/com.nicolai.postgresql16 >/dev/null 2>&1; then
        echo "  com.nicolai.postgresql16 already loaded — plist updated, takes effect at next boot"
    else
        launchctl bootstrap system "${DAEMONS}/com.nicolai.postgresql16.plist"
        echo "  com.nicolai.postgresql16 loaded"
    fi
else
    echo "  SKIPPED (blocked by TCC, BAS-179). Only install after verifying the"
    echo "  Full Disk Access grant:  INSTALL_POSTGRES_DAEMON=1 sudo ./local_launchdaemons/install.sh"
    if [ -f "${DAEMONS}/com.nicolai.postgresql16.plist" ]; then
        echo "  WARNING: ${DAEMONS}/com.nicolai.postgresql16.plist is present — it will hang postgres at next boot."
        echo "           Remove it:  sudo launchctl bootout system/com.nicolai.postgresql16; sudo rm ${DAEMONS}/com.nicolai.postgresql16.plist"
    fi
fi

echo "=== state ==="
/opt/homebrew/bin/wg show || echo "WARNING: wg show reported nothing — tunnel may not be up"

echo
echo "Done. Verify with:  sudo wg show  &&  route -n get 192.168.11.3"
