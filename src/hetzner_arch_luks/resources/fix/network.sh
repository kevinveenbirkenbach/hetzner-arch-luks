#!/bin/bash
# Runs INSIDE the chroot of the installed Arch system. Rewrites every
# systemd-networkd *.network file's [Match] block to use MACAddress= instead
# of Name=. This makes the network config survive kernel / systemd upgrades
# that may rename the interface (predictable naming changes, driver enum).
#
# The MAC is auto-detected via `ip link show` (visible because /sys is bind-
# mounted from rescue — same physical NIC, same MAC).
#
# Idempotent: a .network file that already uses MACAddress= is skipped.
# Backups are kept once at <file>.hal-backup.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

banner "detecting NIC MAC"
# Pick the first non-loopback link with a colon-formatted MAC.
MAC=$(ip -br link show 2>/dev/null \
       | awk '$1 != "lo" && $1 != "" && $3 ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/ {print $3; exit}')

if [ -z "$MAC" ]; then
  echo "Could not auto-detect a non-loopback MAC. Aborting." >&2
  exit 1
fi
echo "Detected MAC: $MAC"

banner ".network files (before)"
for f in /etc/systemd/network/*.network; do
  [ -e "$f" ] || continue
  echo "-- $f:"
  cat "$f"
  echo
done

banner "patching"
changed=0
for f in /etc/systemd/network/*.network; do
  [ -e "$f" ] || continue
  if grep -qE '^[[:space:]]*MACAddress[[:space:]]*=' "$f"; then
    echo "$f: already uses MACAddress= — skipping"
    continue
  fi
  if ! grep -qE '^[[:space:]]*Name[[:space:]]*=' "$f"; then
    echo "$f: no Name= match — skipping"
    continue
  fi
  [ -f "$f.hal-backup" ] || cp -a "$f" "$f.hal-backup"
  awk -v mac="$MAC" '
    BEGIN { replaced=0 }
    /^[[:space:]]*Name[[:space:]]*=/ && !replaced { print "MACAddress=" mac; replaced=1; next }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  echo "$f: patched (backup at $f.hal-backup)"
  changed=1
done
[ "$changed" -eq 0 ] && echo "Nothing to patch — all .network files already use MACAddress=."

banner ".network files (after)"
for f in /etc/systemd/network/*.network; do
  [ -e "$f" ] || continue
  echo "-- $f:"
  cat "$f"
  echo
done

banner "summary"
echo "Done. The change takes effect on the NEXT boot of the installed system."
echo "Backups (if any) are at /etc/systemd/network/*.network.hal-backup."
