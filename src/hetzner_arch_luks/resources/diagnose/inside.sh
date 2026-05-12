#!/bin/bash
# Runs INSIDE the chroot of the installed Arch system. Prints diagnostics
# grouped by banner. Read-only — no state changes.

banner() { printf "\n========== %s ==========\n" "$1"; }

banner "uname / os-release"
uname -a
cat /etc/os-release

banner "package versions (boot/storage/net/ssh)"
pacman -Q linux mkinitcpio openssh systemd device-mapper lvm2 grub \
         cryptsetup mdadm dropbear 2>&1
pacman -Q mkinitcpio-utils mkinitcpio-dropbear mkinitcpio-netconf 2>&1 || true

banner "recent upgrades of boot/network/sshd components (last 60 matches)"
# Focused on the packages that most often break a Hetzner Arch+LUKS boot.
grep -E '\[ALPM\] (upgraded|installed|removed) (linux( |$)|systemd( |$)|mkinitcpio( |$)|openssh( |$)|dropbear( |$)|glibc( |$)|cryptsetup( |$)|lvm2( |$)|mdadm( |$)|grub( |$)|iproute2( |$)|nftables( |$)|iptables( |$)|firewalld( |$)|fail2ban( |$)|mkinitcpio-utils( |$)|mkinitcpio-dropbear( |$)|mkinitcpio-netconf( |$))' /var/log/pacman.log 2>/dev/null \
  | tail -60 \
  || echo "(no matches)"

banner "last full-system upgrade transactions"
grep -nE 'starting full system upgrade|transaction completed' /var/log/pacman.log 2>/dev/null \
  | tail -10 || echo "(no matches)"

banner "initcpio udev rules shipped on disk"
ls -l /usr/lib/initcpio/udev/ 2>&1

banner "is the historically broken file present?"
ls -l /usr/lib/initcpio/udev/11-dm-initramfs.rules 2>&1 || echo "absent"

banner "encryptssh install hook still references it?"
grep -n "11-dm-initramfs.rules" \
  /usr/lib/initcpio/install/encryptssh \
  /etc/initcpio/install/encryptssh 2>/dev/null || echo "no match"

banner "mkinitcpio.conf (HOOKS, MODULES, BINARIES, FILES, COMPRESSION)"
grep -E '^(HOOKS|MODULES|BINARIES|FILES|COMPRESSION)=' /etc/mkinitcpio.conf 2>&1

banner "/etc/crypttab"
cat /etc/crypttab 2>&1 || true

banner "/etc/fstab"
cat /etc/fstab 2>&1 || true

banner "/boot contents and free space"
ls -lh /boot 2>&1
df -h /boot 2>&1

banner "GRUB config + bootloader state"
ls -lh /boot/grub/ 2>&1
echo
if [ -f /boot/grub/grub.cfg ]; then
  if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check /boot/grub/grub.cfg 2>&1 && echo "grub.cfg: syntax OK"
  else
    echo "grub-script-check not available — skipping syntax check"
  fi
  echo
  echo "-- menuentry / linux / initrd lines (first 40):"
  grep -nE '^\s*(linux|initrd|menuentry)' /boot/grub/grub.cfg 2>&1 | head -40

  echo
  echo "-- referenced kernel/initramfs files exist?"
  for p in $(grep -hE '^\s*(linux|initrd)\b' /boot/grub/grub.cfg 2>/dev/null \
              | awk '{print $2}' | sort -u); do
    if   [ -e "$p" ];        then echo "EXISTS  $p"
    elif [ -e "/boot${p}" ]; then echo "EXISTS  /boot${p}  (grub.cfg path: $p)"
    else                          echo "MISSING $p"
    fi
  done
else
  echo "/boot/grub/grub.cfg NOT FOUND"
fi
echo
echo "-- grubenv:"
grub-editenv /boot/grub/grubenv list 2>/dev/null || cat /boot/grub/grubenv 2>/dev/null | head -5 || echo "(no grubenv)"

banner "initramfs contents — key tools actually packed in?"
if command -v lsinitcpio >/dev/null 2>&1; then
  echo "-- matches in /boot/initramfs-linux.img:"
  lsinitcpio /boot/initramfs-linux.img 2>/dev/null \
    | grep -E '(cryptsetup|dropbear|encryptssh|netconf|mdadm|lvm|/init$|hooks/)' \
    | sort -u | head -50
else
  echo "lsinitcpio not available"
fi

banner "network: which service manages it?"
for u in systemd-networkd NetworkManager netctl-auto dhcpcd; do
  printf "  %-22s %s\n" "$u" "$(systemctl is-enabled "$u" 2>&1)"
done
# dhcpcd@interface units (Arch default for static-ish setups)
systemctl list-unit-files 'dhcpcd@*' --no-pager 2>/dev/null | grep -E 'dhcpcd@' || true

banner "network: config files present"
echo "-- /etc/systemd/network/"
ls -la /etc/systemd/network/ 2>&1 | head -20 || echo "(empty/missing)"
echo
echo "-- /etc/NetworkManager/system-connections/"
ls -la /etc/NetworkManager/system-connections/ 2>&1 | head -20 || echo "(empty/missing)"
echo
echo "-- /etc/netctl/"
ls -la /etc/netctl/ 2>&1 | head -20 || echo "(empty/missing)"
echo
echo "-- /etc/hostname / /etc/hosts"
cat /etc/hostname 2>&1 || true
echo "---"
cat /etc/hosts 2>&1 || true

banner "firewall units (would persist across reboots)"
for u in nftables iptables ip6tables firewalld ufw fail2ban docker; do
  printf "  %-12s %s\n" "$u" "$(systemctl is-enabled "$u" 2>&1)"
done
echo
if [ -f /etc/nftables.conf ]; then
  echo "-- /etc/nftables.conf (first 60 lines):"
  head -60 /etc/nftables.conf
fi
[ -f /etc/iptables/iptables.rules ] && { echo "-- /etc/iptables/iptables.rules (head 40):"; head -40 /etc/iptables/iptables.rules; }

banner "sshd state + drop-ins"
sshd -t 2>&1
systemctl is-enabled sshd 2>&1
grep -nE '^Port|^ListenAddress|^PermitRootLogin' /etc/ssh/sshd_config 2>&1 || true
echo
echo "-- sshd_config.d/ drop-ins (can override main config!):"
ls -la /etc/ssh/sshd_config.d/ 2>&1 || echo "(no drop-ins dir)"
for f in /etc/ssh/sshd_config.d/*.conf; do
  [ -e "$f" ] || continue
  echo
  echo "-- $f:"
  cat "$f"
done

banner "journal: which boots are actually recorded?"
journalctl --list-boots --no-pager 2>&1 | tail -15

banner "last recorded boot (-b 0): all errors"
journalctl -b 0 -p err --no-pager 2>&1 | head -100 || true

banner "last recorded boot (-b 0): sshd"
journalctl -b 0 -u sshd --no-pager 2>&1 | head -40 || true

banner "last recorded boot (-b 0): cryptsetup / dropbear / network units"
journalctl -b 0 \
  -u 'systemd-cryptsetup*' -u 'dropbear*' \
  -u 'systemd-networkd*' -u 'NetworkManager*' -u 'dhcpcd*' \
  --no-pager 2>&1 | head -80 || true

banner "previous boot (-b -1): errors (only if a previous boot is recorded)"
journalctl -b -1 -p err --no-pager 2>&1 | head -50 || true

banner "failed units of last boot"
systemctl --failed --no-pager 2>&1 || true
