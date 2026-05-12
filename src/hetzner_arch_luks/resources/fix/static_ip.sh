#!/bin/bash
# Replaces `ip=dhcp` in /etc/default/grub with a static kernel-cmdline
# network spec derived from the existing /etc/systemd/network/*.network file.
#
# Why: Dropbear-in-initramfs relies on a working network for remote LUKS
# unlock. On Hetzner Dedicated, `ip=dhcp` is fragile — Hetzner's own docs
# recommend static configuration for FDE+Dropbear setups. A kernel/iproute2
# upgrade can subtly change the DHCP request format and break the
# previously-working DHCP path.
#
# The .network file already has the correct values (IP, gateway). This
# script reuses them in the kernel cmdline so dropbear has network in
# initramfs without depending on Hetzner DHCP.
#
# Resulting cmdline format (Linux kernel `ip=` documented form):
#   ip=<client>:<server>:<gateway>:<netmask>:<hostname>:<device>:<protocol>
# We use:
#   ip=46.4.224.77::46.4.224.65:255.255.255.255:echoserver:eth0:none
#
# Idempotent: re-running won't double-patch.
# Reversible: original /etc/default/grub backed up to .hal-backup.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

banner "locating systemd-networkd config"
NETFILE=""
for f in /etc/systemd/network/*.network; do
  [ -e "$f" ] || continue
  NETFILE="$f"
  break
done
if [ -z "$NETFILE" ]; then
  echo "ERROR: no /etc/systemd/network/*.network file found."
  echo "       Cannot derive static IP/gateway."
  exit 1
fi
echo "Using: $NETFILE"
echo
cat "$NETFILE"

banner "parsing"
# IPv4 address: first Address= or [Address]/Address= line without colon.
IPV4=$(awk '
  /^[[:space:]]*Address[[:space:]]*=/ {
    sub(/^[[:space:]]*Address[[:space:]]*=[[:space:]]*/, "")
    if ($0 !~ /:/) { print; exit }
  }
' "$NETFILE")
IPV4_BARE="${IPV4%%/*}"

# Gateway: first IPv4 Gateway= line.
GATEWAY=$(awk '
  /^[[:space:]]*Gateway[[:space:]]*=/ {
    sub(/^[[:space:]]*Gateway[[:space:]]*=[[:space:]]*/, "")
    if ($0 !~ /:/) { print; exit }
  }
' "$NETFILE")

HOST="$(cat /etc/hostname 2>/dev/null | head -1 | tr -d ' \t\n' || true)"
[ -z "$HOST" ] && HOST="host"

# Device: 'eth0' matches the kernel pre-udev naming of the first ethernet
# interface and is what Hetzner uses in their FDE-static-IP docs.
DEVICE="eth0"

echo "  IPv4:     $IPV4_BARE"
echo "  Gateway:  $GATEWAY"
echo "  Hostname: $HOST"
echo "  Device:   $DEVICE"

if [ -z "$IPV4_BARE" ] || [ -z "$GATEWAY" ]; then
  echo "ERROR: could not parse IPv4 address or gateway from $NETFILE."
  exit 1
fi

IPSPEC="ip=${IPV4_BARE}::${GATEWAY}:255.255.255.255:${HOST}:${DEVICE}:none"
echo
echo "Will set kernel cmdline param: $IPSPEC"

banner "current /etc/default/grub"
cat /etc/default/grub

banner "patching /etc/default/grub"
if grep -qE 'ip=dhcp' /etc/default/grub; then
  [ -f /etc/default/grub.hal-backup ] || cp -a /etc/default/grub /etc/default/grub.hal-backup
  # Replace just the ip=dhcp token (leaves all other kernel params untouched)
  sed -i -E "s|ip=dhcp|${IPSPEC}|g" /etc/default/grub
  echo "Replaced ip=dhcp → $IPSPEC"
  echo "Backup: /etc/default/grub.hal-backup"
elif grep -qE "ip=${IPV4_BARE//./\\.}::" /etc/default/grub; then
  echo "Static ip= already configured for $IPV4_BARE — no change."
elif grep -qE 'ip=' /etc/default/grub; then
  echo "WARNING: /etc/default/grub has an ip= directive that's neither dhcp"
  echo "         nor the expected static spec. Manual review needed:"
  grep -nE 'ip=' /etc/default/grub
  echo "Aborting — won't blindly overwrite an unknown ip= value."
  exit 1
else
  echo "No ip= directive found in GRUB_CMDLINE_LINUX. Manual edit may be needed."
  exit 1
fi

banner "patched /etc/default/grub"
cat /etc/default/grub

banner "regenerating /boot/grub/grub.cfg"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -10

banner "verifying"
echo "-- ip= lines in new grub.cfg:"
grep -nE '\bip=' /boot/grub/grub.cfg | head -5 || echo "(no ip= line found — unexpected)"

banner "next steps"
cat <<EOF
1. Exit chroot, umount -R /mnt, reboot.
2. If system boots and SSH works:
     → Root cause was DHCP-in-initramfs fragility (Hetzner side / iproute2
       behavior change). Static cmdline IP is the recommended permanent fix.
3. To revert (if anything goes wrong):
     cp /etc/default/grub.hal-backup /etc/default/grub
     grub-mkconfig -o /boot/grub/grub.cfg
EOF
