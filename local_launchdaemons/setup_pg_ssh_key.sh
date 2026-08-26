#!/bin/bash
# One-time (and after any change to pg_autostart_cmd.sh's path) setup of the
# localhost SSH key the postgres boot launcher uses. Run WITHOUT sudo, after
# `sudo ./local_launchdaemons/install.sh` has put pg_autostart_cmd.sh in
# /usr/local/libexec.
#
# The key can only connect from this machine and can only run the forced
# command (start postgres) — no shell, no pty, no forwarding.

set -euo pipefail

SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/pg_autostart_ed25519"
CMD="/usr/local/libexec/pg_autostart_cmd.sh"
AK="$SSH_DIR/authorized_keys"

[ -x "$CMD" ] || { echo "ERROR: $CMD missing — run sudo ./local_launchdaemons/install.sh first" >&2; exit 1; }

mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C pg-autostart-localhost -f "$KEY"

PUB=$(cut -d' ' -f1,2 "$KEY.pub")
LINE="command=\"$CMD\",from=\"127.0.0.1,::1\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty $PUB pg-autostart-localhost"

touch "$AK"
grep -v ' pg-autostart-localhost$' "$AK" > "$AK.tmp" || true
echo "$LINE" >> "$AK.tmp"
mv "$AK.tmp" "$AK"; chmod 600 "$AK"
rm -f "$SSH_DIR/pg_autostart_cmd.sh"   # the probe-era copy, superseded by $CMD

echo "authorized_keys entry installed. Test (safe, idempotent):"
echo "  ssh -o BatchMode=yes -i $KEY 127.0.0.1"
