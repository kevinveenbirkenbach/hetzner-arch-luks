#!/bin/bash
# Runs INSIDE the chroot. Downgrades the 5 packages that determine how the
# initramfs is built AND what binaries end up inside it, to the version
# they had before the most recent `pacman -Syu`.
#
# The 5 packages:
#   mkinitcpio   — build tool. mkinitcpio 41 changed hook handling and may
#                  silently break setups using older third-party hooks
#                  (mkinitcpio-utils / -dropbear / -netconf).
#   dropbear     — SSH daemon in initramfs for remote LUKS unlock. The
#                  2025.89 → 2026.90 jump may have changed key/config format.
#   cryptsetup   — LUKS open in initramfs.
#   mdadm        — RAID assemble in initramfs.
#   lvm2         — LVM activate in initramfs.
#
# Source: /var/log/pacman.log tells us the exact previous versions.
# Files: prefer /var/cache/pacman/pkg/, fall back to archive.archlinux.org.
# After: rebuilds initramfs and regenerates grub.cfg.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

PKGS=(mkinitcpio dropbear cryptsetup mdadm lvm2)

# Arch convention for package-file naming.
pkg_arch() {
  case "$1" in
    mkinitcpio|mkinitcpio-utils|mkinitcpio-dropbear|mkinitcpio-netconf) echo "any" ;;
    *) echo "x86_64" ;;
  esac
}

# Extract previous version from the most recent
# "[ALPM] upgraded <pkg> (OLD -> NEW)" line in pacman.log.
prev_version() {
  local pkg="$1"
  grep -E "\[ALPM\] upgraded $pkg \(" /var/log/pacman.log 2>/dev/null \
    | tail -1 \
    | sed -E "s/.*upgraded $pkg \(([^ ]+) -> [^)]+\).*/\1/"
}

banner "discovering previous versions from pacman.log"
declare -A FNAMES
TARGETS=()
for pkg in "${PKGS[@]}"; do
  prev=$(prev_version "$pkg")
  curr=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
  if [ -z "$prev" ]; then
    echo "  $pkg: no 'upgraded' entry in pacman.log — SKIP"
    continue
  fi
  if [ "$prev" = "$curr" ]; then
    echo "  $pkg: already at previous version $curr — skip"
    continue
  fi
  arch=$(pkg_arch "$pkg")
  fname="${pkg}-${prev}-${arch}.pkg.tar.zst"
  echo "  $pkg: $curr → $prev   ($fname)"
  FNAMES[$pkg]="$fname"
  TARGETS+=("$pkg")
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "Nothing to downgrade."
  exit 0
fi

banner "fetching packages"
FILES=()
for pkg in "${TARGETS[@]}"; do
  fname="${FNAMES[$pkg]}"
  cache="/var/cache/pacman/pkg/$fname"
  if [ -e "$cache" ]; then
    echo "  $pkg: cached → $cache"
    FILES+=("$cache")
    continue
  fi
  first_letter="${pkg:0:1}"
  url="https://archive.archlinux.org/packages/${first_letter}/${pkg}/${fname}"
  out="/tmp/$fname"
  echo "  $pkg: fetching"
  echo "    URL: $url"
  if curl -fsSL --connect-timeout 15 -o "$out" "$url"; then
    size=$(du -h "$out" | cut -f1)
    echo "    OK ($size)"
    FILES+=("$out")
  else
    echo "    FAILED — cannot continue without all packages"
    exit 1
  fi
done

banner "downgrading (single transaction)"
pacman -U --noconfirm "${FILES[@]}"

banner "rebuilding initramfs (with downgraded mkinitcpio + tools)"
mkinitcpio -P

banner "regenerating GRUB config"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -10

banner "result"
for pkg in "${PKGS[@]}"; do
  pacman -Q "$pkg" 2>/dev/null || true
done

banner "next steps"
cat <<EOF
1. Exit chroot, umount -R /mnt, reboot.
2. If the system boots and SSH works:
     → root cause is in one of {mkinitcpio, dropbear, cryptsetup, mdadm, lvm2}.
     Pin them so the next pacman -Syu does not re-upgrade:
       IgnorePkg = ${PKGS[*]}
     in /etc/pacman.conf. Bisect later to find the exact culprit.
3. If still unbootable:
     → not the initramfs stack. Remaining suspects: glibc, systemd, iproute2.
     Next attempt would be a full rollback of all May-11 package upgrades.
EOF
