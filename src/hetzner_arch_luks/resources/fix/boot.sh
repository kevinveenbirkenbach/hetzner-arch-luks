#!/bin/bash
# Runs INSIDE the chroot of the installed Arch system. Applies the recommended
# boot / SSH fixes:
#
#   1. PermitRootLogin: rewrite a literal "no" line to "prohibit-password"
#      in /etc/ssh/sshd_config AND any drop-in under /etc/ssh/sshd_config.d/.
#      Backups are kept once as *.hal-backup.
#   2. Persistent journald: create /var/log/journal so journald survives
#      reboot (next boot onwards). Helps catch the next failure if there is one.
#
# Idempotent: re-running is safe — no-op on already-fixed configs.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

banner "PermitRootLogin (before)"
grep -rn '^PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
  || echo "(no explicit setting found)"

changed=0
for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  [ -e "$f" ] || continue
  if grep -q '^PermitRootLogin no$' "$f"; then
    [ -f "$f.hal-backup" ] || cp -a "$f" "$f.hal-backup"
    sed -i 's/^PermitRootLogin no$/PermitRootLogin prohibit-password/' "$f"
    echo "==> Patched: $f  (backup at $f.hal-backup)"
    changed=1
  fi
done
[ "$changed" -eq 0 ] && echo "==> Nothing to patch — PermitRootLogin is not 'no' anywhere."

banner "PermitRootLogin (after)"
grep -rn '^PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
  || echo "(no explicit setting found)"

banner "sshd_config syntax check"
sshd -t && echo "syntax OK"

banner "persistent journald"
if [ ! -d /var/log/journal ]; then
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal 2>&1 || true
  echo "==> Created /var/log/journal. journald will persist from next boot onwards."
else
  echo "/var/log/journal already exists — journald is already persistent."
fi

banner "/boot space"
df -h /boot
ls -lh /boot

banner "summary"
echo "Done. The changes take effect on the NEXT boot of the installed system."
echo "Exit the chroot and reboot out of rescue when ready."
