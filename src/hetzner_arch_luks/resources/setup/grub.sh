#!/bin/bash
# Runs INSIDE the chroot. Initial GRUB install for the LUKS-encrypted root.
# Performs sections 5.1–5.3 of the README:
#   - install the grub package
#   - write /etc/default/grub with the LUKS cmdline + GRUB_ENABLE_CRYPTODISK=y
#   - grub-mkconfig
#   - grub-install on every disk backing /boot's RAID

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

# Convert a partition path to its parent disk. (Same helper as fix/grub.sh.)
parent_disk() {
  local part="$1"
  case "$part" in
    /dev/nvme[0-9]*n[0-9]*p[0-9]*)   echo "${part%p[0-9]*}" ;;
    /dev/mmcblk[0-9]*p[0-9]*)        echo "${part%p[0-9]*}" ;;
    /dev/sd[a-z]*[0-9]*)             echo "$part" | sed -E 's/[0-9]+$//' ;;
    /dev/vd[a-z]*[0-9]*)             echo "$part" | sed -E 's/[0-9]+$//' ;;
    *)
      local d
      d=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
      [ -n "$d" ] && echo "/dev/$d"
      ;;
  esac
}

banner "installing grub package"
pacman -S --noconfirm --needed grub

banner "writing /etc/default/grub for LUKS boot"
[ -f /etc/default/grub.hal-backup ] || cp -a /etc/default/grub /etc/default/grub.hal-backup
cat > /etc/default/grub <<'GRUBEOF'
# hetzner-arch-luks default grub config
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="consoleblank=0"
GRUB_CMDLINE_LINUX="cryptdevice=/dev/md1:cryptroot ip=dhcp"
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_ENABLE_CRYPTODISK=y
GRUB_TIMEOUT_STYLE=menu
GRUB_TERMINAL_INPUT=console
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_DISABLE_RECOVERY=true
GRUBEOF

echo "Wrote /etc/default/grub. Showing relevant lines:"
grep -E '^GRUB_(CMDLINE_LINUX|ENABLE_CRYPTODISK|PRELOAD_MODULES)=' /etc/default/grub

banner "identifying boot disks (members of md0)"
BOOT_DISKS=()
for part in $(mdadm --detail /dev/md0 2>/dev/null | awk '/active sync/ {print $NF}'); do
  disk=$(parent_disk "$part")
  [ -z "$disk" ] && continue
  already=0
  for d in "${BOOT_DISKS[@]}"; do [ "$d" = "$disk" ] && already=1; done
  [ "$already" -eq 0 ] && BOOT_DISKS+=("$disk")
done
echo "Boot disks: ${BOOT_DISKS[*]}"

banner "grub-mkconfig"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -10

banner "grub-install on each boot disk"
for disk in "${BOOT_DISKS[@]}"; do
  echo "-- grub-install --target=i386-pc --recheck $disk"
  grub-install --target=i386-pc --recheck "$disk"
done

banner "done"
cat <<EOF
GRUB installed for LUKS-encrypted boot.
Recommended next step:  hal use-static-ip <host>   (replaces ip=dhcp with a
static kernel-cmdline IP, making the initramfs network independent of DHCP).
EOF
