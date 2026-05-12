#!/bin/bash
# Runs INSIDE the chroot. Full pacman -Syu + initramfs rebuild + GRUB refresh
# (config + MBR on every disk backing /boot's RAID).
#
# CRITICAL: pacman 7.x uses Linux Landlock for its sandbox protection. The
# Hetzner Rescue kernel does NOT enable Landlock, so pacman -Syu inside the
# chroot would fail at the database-sync step with:
#   error: restricting filesystem access failed because Landlock is not supported
#   error: switching to sandbox user 'alpm' failed!
# The --disable-sandbox flag works around this. Outside the rescue context
# (e.g. on the live system later) the flag is unnecessary.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

# Convert a partition path to its parent disk. lsblk fails inside our chroot
# (can't resolve PKNAME against the rescue-bound /sys), so use standard
# Linux device-naming conventions instead. (Same helper as fix/grub.sh.)
parent_disk() {
  local part="$1"
  case "$part" in
    /dev/nvme[0-9]*n[0-9]*p[0-9]*)   echo "${part%p[0-9]*}" ;;
    /dev/mmcblk[0-9]*p[0-9]*)        echo "${part%p[0-9]*}" ;;
    /dev/loop[0-9]*p[0-9]*)          echo "${part%p[0-9]*}" ;;
    /dev/sd[a-z]*[0-9]*)             echo "$part" | sed -E 's/[0-9]+$//' ;;
    /dev/vd[a-z]*[0-9]*)             echo "$part" | sed -E 's/[0-9]+$//' ;;
    /dev/hd[a-z]*[0-9]*)             echo "$part" | sed -E 's/[0-9]+$//' ;;
    *)
      local d
      d=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
      [ -n "$d" ] && echo "/dev/$d"
      ;;
  esac
}

banner "pre-upgrade state"
echo "-- key packages BEFORE:"
pacman -Q linux mkinitcpio systemd openssh dropbear cryptsetup mdadm lvm2 grub 2>&1 | head -15
echo
echo "-- /boot space BEFORE:"
df -h /boot

banner "running pacman -Syyu (with --disable-sandbox for Rescue kernel)"
pacman --disable-sandbox -Syyu --noconfirm

banner "rebuilding initramfs"
mkinitcpio -P

banner "identifying boot disks (members of md0)"
if [ ! -e /dev/md0 ]; then
  echo "ERROR: /dev/md0 not present. RAID not assembled? Aborting GRUB step."
  exit 1
fi
BOOT_DISKS=()
for part in $(mdadm --detail /dev/md0 2>/dev/null | awk '/active sync/ {print $NF}'); do
  disk=$(parent_disk "$part")
  [ -z "$disk" ] && { echo "WARN: cannot resolve parent disk for $part"; continue; }
  already=0
  for d in "${BOOT_DISKS[@]}"; do [ "$d" = "$disk" ] && already=1; done
  [ "$already" -eq 0 ] && BOOT_DISKS+=("$disk")
done
echo "Boot disks: ${BOOT_DISKS[*]}"

banner "refreshing GRUB on all boot disks"
for disk in "${BOOT_DISKS[@]}"; do
  echo
  echo "-- grub-install --target=i386-pc --recheck $disk"
  grub-install --target=i386-pc --recheck "$disk"
done

banner "regenerating /boot/grub/grub.cfg"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -10

banner "post-upgrade state"
echo "-- key packages AFTER:"
pacman -Q linux mkinitcpio systemd openssh dropbear cryptsetup mdadm lvm2 grub 2>&1 | head -15
echo
echo "-- /boot space AFTER:"
df -h /boot

banner "summary"
cat <<EOF
System fully upgraded. Boot stack refreshed:
  - All packages on current state from Arch repos
  - initramfs rebuilt for the current kernel
  - GRUB stage1 + core.img re-written on all boot disks
  - grub.cfg regenerated

Recommended next steps:
  1. (Optional but recommended) Run \`hal use-static-ip <host>\` afterwards to
     harden the initramfs network against future DHCP issues.
  2. Exit chroot, umount -R /mnt, reboot, disable Rescue in Hetzner Robot.
  3. Watch with: hal status <host>
EOF
