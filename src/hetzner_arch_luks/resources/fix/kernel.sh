#!/bin/bash
# Runs INSIDE the chroot. Downgrades the linux kernel to the previous
# version (the one running BEFORE the most recent `pacman upgraded linux`
# in /var/log/pacman.log). Looks in /var/cache/pacman/pkg/ first; if not
# present, fetches from https://archive.archlinux.org/.
#
# After downgrade: regenerates initramfs + grub.cfg.
#
# Use case: a `pacman -Syu` bumped the kernel to a version that fails to
# boot on this hardware. Rolling the kernel back leaves every other
# package on the new version, so this isolates the kernel as a variable.
#
# Idempotent: if already on the previous version, exits as a no-op.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

banner "determining previous kernel version from pacman.log"
PREV=$(grep -E '\[ALPM\] upgraded linux \(' /var/log/pacman.log 2>/dev/null \
       | tail -1 \
       | sed -E 's/.*upgraded linux \(([^ ]+) -> [^)]+\).*/\1/')
CURR=$(pacman -Q linux | awk '{print $2}')

if [ -z "$PREV" ]; then
  echo "FATAL: Could not parse a previous kernel version from /var/log/pacman.log."
  echo "       Pacman log entries for 'linux' upgrades:"
  grep -E '\[ALPM\] (installed|upgraded) linux \(' /var/log/pacman.log 2>/dev/null \
    | tail -5 || echo "       (none found)"
  exit 1
fi

echo "Currently installed: linux-$CURR"
echo "Previous version:    linux-$PREV"

if [ "$PREV" = "$CURR" ]; then
  echo "Already on the previous version. Nothing to do."
  exit 0
fi

PKG_NAME="linux-${PREV}-x86_64.pkg.tar.zst"
CACHE_PATH="/var/cache/pacman/pkg/${PKG_NAME}"

banner "locating package"
TARGET=""
if [ -e "$CACHE_PATH" ]; then
  echo "Found in cache: $CACHE_PATH"
  TARGET="$CACHE_PATH"
else
  echo "Not in cache. Fetching from archive.archlinux.org ..."
  URL="https://archive.archlinux.org/packages/l/linux/${PKG_NAME}"
  echo "URL: $URL"
  if curl -fsSL --connect-timeout 15 -o "/tmp/${PKG_NAME}" "$URL"; then
    TARGET="/tmp/${PKG_NAME}"
    echo "Downloaded: $TARGET ($(du -h "$TARGET" | cut -f1))"
  else
    cat <<EOF >&2

Download failed from $URL.
Reasons might be:
  - chroot has no working DNS / no outbound network
  - the specific version is no longer on archive.archlinux.org
  - upstream temporarily unavailable

Workarounds:
  1. Test network from chroot:
       curl -v https://archive.archlinux.org/
  2. Manually download on your client:
       curl -O $URL
     and SCP into rescue, then place at:
       /mnt/tmp/${PKG_NAME}
     (Inside the chroot it appears as /tmp/${PKG_NAME}.)
  3. Pick a different version — list at:
       https://archive.archlinux.org/packages/l/linux/
EOF
    exit 1
  fi
fi

banner "/boot space before"
df -h /boot
ls -lh /boot

banner "downgrading kernel (pacman -U)"
pacman -U --noconfirm "$TARGET"

banner "regenerating initramfs"
mkinitcpio -P

banner "regenerating GRUB config"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -10

banner "/boot space after"
df -h /boot
ls -lh /boot

banner "result"
pacman -Q linux

banner "next steps"
cat <<EOF
1. Exit chroot, umount -R /mnt, reboot.
2. If system boots and SSH works:
     → root cause confirmed = linux $CURR incompatible on this hardware.
     Pin the kernel by adding to /etc/pacman.conf:
       IgnorePkg = linux
     OR install linux-lts and switch to it as the primary kernel.
3. If still unbootable:
     → kernel was not the cause. Next bisection target: systemd.
EOF
