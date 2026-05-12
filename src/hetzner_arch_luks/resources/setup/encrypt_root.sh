#!/bin/bash
# Runs IN HETZNER RESCUE (NOT in chroot). Re-creates the root LV stack on
# top of LUKS, preserving the installed Arch by copying it through /oldroot.
#
# Performs sections 4.4–4.15 of the README in one go:
#   4.4  mount the unencrypted /dev/mapper/vg0-root
#   4.5  cp -va /mnt → /oldroot at full RAID resync speed
#   4.6  umount /mnt
#   4.7  vgremove vg0
#   4.8  cat /proc/mdstat (display)
#   4.9  luksFormat /dev/md1 (prompts for NEW passphrase!)
#        luksOpen + recreate LVM (vg0 with swap + root)
#        mkfs.btrfs / mkswap
#   4.10 mount the encrypted root at /mnt
#   4.12 cp -va /oldroot back into /mnt at full RAID resync speed
#   4.13 bind /dev /sys /proc, mount /boot
#   4.14 echo cryptroot line into /mnt/etc/crypttab
#   4.15 chroot + mkinitcpio -P
#
# DESTRUCTIVE: /dev/md1 will be re-formatted with LUKS. Any data not under
# /mnt (vg0-root) is lost. Confirmation prompted before the format step.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

banner "4.4 mount existing unencrypted root"
vgscan -v
vgchange -a y
mount /dev/mapper/vg0-root /mnt

banner "4.5 copy current system to /oldroot (full RAID resync speed)"
mkdir -p /oldroot
echo 0 > /proc/sys/dev/raid/speed_limit_max
cp -va /mnt/. /oldroot/.
echo 200000 > /proc/sys/dev/raid/speed_limit_max

banner "4.6 unmount original root"
umount /mnt

banner "4.7 remove unencrypted VG (frees /dev/md1)"
vgremove -f vg0

banner "4.8 RAID state"
cat /proc/mdstat

banner "CONFIRMATION REQUIRED"
echo "About to luksFormat /dev/md1. This is DESTRUCTIVE for /dev/md1."
echo "Type 'YES' to continue (anything else aborts):"
read -r confirm
if [ "$confirm" != "YES" ]; then
  echo "Aborted by user before luksFormat. /oldroot still has your data;"
  echo "you can re-create the original LVM by hand from there if needed."
  exit 1
fi

banner "4.9 LUKS format /dev/md1 (you will be prompted for the NEW passphrase)"
cryptsetup --cipher aes-xts-plain64 --key-size 256 --hash sha256 \
           --iter-time 10000 luksFormat /dev/md1

banner "4.9b open the LUKS volume (re-enter the same passphrase)"
cryptsetup luksOpen /dev/md1 cryptroot

banner "4.9c recreate LVM on top of /dev/mapper/cryptroot"
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
lvcreate -n swap -L 8G vg0
lvcreate -n root -l 100%FREE vg0
mkfs.btrfs /dev/vg0/root
mkswap /dev/vg0/swap

banner "4.10 mount the encrypted root"
mount /dev/vg0/root /mnt

banner "4.12 copy system back into the encrypted root"
echo 0 > /proc/sys/dev/raid/speed_limit_max
cp -va /oldroot/. /mnt/.
echo 200000 > /proc/sys/dev/raid/speed_limit_max

banner "4.13 bind-mount /dev /sys /proc, mount /boot"
mount /dev/md0 /mnt/boot
mount --bind /dev /mnt/dev
mount --bind /sys /mnt/sys
mount --bind /proc /mnt/proc

banner "4.14 append cryptroot line to /etc/crypttab"
if ! grep -qE '^cryptroot[[:space:]]' /mnt/etc/crypttab 2>/dev/null; then
  echo "cryptroot /dev/md1 none luks" >> /mnt/etc/crypttab
fi
grep cryptroot /mnt/etc/crypttab

banner "4.15 regenerate initramfs inside chroot"
chroot /mnt /bin/bash -c "mkinitcpio -P"

banner "done"
cat <<EOF
Encryption setup complete. /oldroot can be deleted manually after you've
confirmed the encrypted boot works.

Recommended next steps:
  hal install-grub <host>     # configures GRUB for LUKS-encrypted root
  hal connect rescue <host> reboot
  # Disable rescue in Hetzner Robot
  hal status <host>           # poll for dropbear / sshd
  hal unlock <host>           # send LUKS passphrase to dropbear
EOF
