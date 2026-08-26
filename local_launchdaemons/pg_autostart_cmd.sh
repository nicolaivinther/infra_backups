#!/bin/bash
# Forced command for the pg-autostart SSH key. Runs UNDER sshd, which is the
# whole point: macOS TCC attributes file access to the responsible process,
# and sshd (Remote Login) holds Full Disk Access while a launchd job does not.
# So the LaunchDaemon cannot read /Volumes/MiniData itself, but a process it
# reaches through `ssh localhost` can. See CLAUDE.md "PostgreSQL auto-start".
#
# Installed by install.sh to /usr/local/libexec (root-owned, so the key holder
# cannot change what the key runs). Referenced from ~/.ssh/authorized_keys via
# command="/usr/local/libexec/pg_autostart_cmd.sh" — set up by setup_pg_ssh_key.sh.
#
# Idempotent: exits 0 if a postmaster is already running.

set -uo pipefail

DATA_DIR="/Volumes/MiniData/postgres_data"
PG_BIN="/opt/homebrew/opt/postgresql@16/bin"
LOG="/Users/nicolaitanghoj/Library/Logs/postgresql16.log"
export LANG=C.UTF-8 LC_ALL=C.UTF-8

if "$PG_BIN/pg_ctl" -D "$DATA_DIR" status >/dev/null 2>&1; then
    echo "postmaster already running"
    exit 0
fi

# pg_ctl detaches postgres into its own session; TCC responsibility was fixed
# at exec under sshd, so the grant survives the ssh session ending.
"$PG_BIN/pg_ctl" -D "$DATA_DIR" -l "$LOG" -w -t 300 start
