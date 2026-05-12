#!/bin/bash
# Re-install GRUB stage1 + core.img to the MBR of every physical disk that
# backs /boot's RAID array. Needed when a `pacman -Syu` updated the grub
# package but grub-install was never re-run afterwards, leaving stale
# Stage1 code in the MBR that may not understand the new modules in
# /boot/grub/i386-pc/.
#
# Also regenerates /boot/grub/grub.cfg.
#
# Boot disks are auto-detected from the components of /dev/md0.
# Targets BIOS GRUB (--target=i386-pc); the existing /boot/grub/i386-pc/
# directory confirms this is a BIOS setup.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

banner "current /boot/grub state"
ls -lh /boot/grub/
echo
echo "-- /boot/grub/i386-pc/ — most recent files:"
ls -lt /boot/grub/i386-pc/ 2>/dev/null | head -8

banner "identifying boot disks (members of md0)"
if [ ! -e /dev/md0 ]; then
  echo "ERROR: /dev/md0 does not exist. Was the RAID assembled before chroot?"
  exit 1
fi
echo "-- mdadm --detail /dev/md0 (member partitions):"
mdadm --detail /dev/md0 | awk '/active sync/ {print "  " $NF}'

# Convert a partition path to its parent disk. lsblk fails inside our chroot
# (can't resolve PKNAME against the rescue-bound /sys), so use the standard
# Linux device naming conventions instead.
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
      # Last resort — try lsblk; may return empty in chroot
      local d
      d=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
      [ -n "$d" ] && echo "/dev/$d"
      ;;
  esac
}

BOOT_DISKS=()
for part in $(mdadm --detail /dev/md0 2>/dev/null | awk '/active sync/ {print $NF}'); do
  disk=$(parent_disk "$part")
  [ -z "$disk" ] && { echo "WARN: cannot resolve parent disk for $part"; continue; }
  already=0
  for d in "${BOOT_DISKS[@]}"; do [ "$d" = "$disk" ] && already=1; done
  [ "$already" -eq 0 ] && BOOT_DISKS+=("$disk")
done

if [ "${#BOOT_DISKS[@]}" -eq 0 ]; then
  echo "ERROR: could not detect any boot disks."
  exit 1
fi
echo
echo "Will run grub-install on: ${BOOT_DISKS[*]}"

banner "regenerating /boot/grub/grub.cfg"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -10

banner "reinstalling GRUB to each boot disk"
for disk in "${BOOT_DISKS[@]}"; do
  echo
  echo "-- grub-install --target=i386-pc --recheck $disk"
  grub-install --target=i386-pc --recheck "$disk"
done

banner "post-install state"
echo "-- /boot/grub/i386-pc/ — newest files now:"
ls -lt /boot/grub/i386-pc/ 2>/dev/null | head -6

banner "next steps"
cat <<EOF
1. Exit chroot, umount -R /mnt, reboot.
2. If the system boots normally:
     → root cause confirmed = stale MBR after grub package upgrades
       (grub-install was never re-run after a pacman -Syu touched grub).
     → To prevent recurrence, add a pacman hook (Arch wiki: "GRUB").
3. If still unbootable:
     → GRUB stage1 was not the cause. Next bisection: downgrade systemd.
EOF
