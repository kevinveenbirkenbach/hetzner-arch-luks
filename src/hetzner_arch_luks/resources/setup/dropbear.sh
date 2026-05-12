#!/bin/bash
# Runs on the BOOTED Arch system (post-installimage, pre-encryption).
# Wires up dropbear + encryptssh + netconf for later remote-LUKS-unlock.
#
# Performs sections 3.1–3.5 of the README:
#   - install busybox / mkinitcpio-{dropbear,utils,netconf}
#   - copy authorized_keys to /etc/dropbear/root_key
#   - regenerate OpenSSH host keys in PEM format
#   - convert RSA host key to dropbear format
#   - replace the HOOKS line in /etc/mkinitcpio.conf
#
# Idempotent: re-running is safe. A backup of /etc/mkinitcpio.conf is taken
# at first patch as /etc/mkinitcpio.conf.hal-backup.

set -e

banner() { printf "\n========== %s ==========\n" "$1"; }

banner "installing dropbear + mkinitcpio plugins"
pacman -S --noconfirm --needed \
  busybox mkinitcpio-dropbear mkinitcpio-utils mkinitcpio-netconf

banner "copying authorized_keys to /etc/dropbear/root_key"
install -d -m 0755 /etc/dropbear
install -m 0600 /root/.ssh/authorized_keys /etc/dropbear/root_key
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

banner "enabling sshd"
systemctl enable sshd

banner "regenerating OpenSSH host keys (PEM format)"
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A -m PEM

banner "importing RSA host key into dropbear"
dropbearconvert openssh dropbear \
  /etc/ssh/ssh_host_rsa_key /etc/dropbear/dropbear_rsa_host_key

banner "patching HOOKS in /etc/mkinitcpio.conf"
[ -f /etc/mkinitcpio.conf.hal-backup ] \
  || cp -a /etc/mkinitcpio.conf /etc/mkinitcpio.conf.hal-backup

# Replace any existing HOOKS=(...) line with the encryptssh-enabled set.
sed -i -E \
  's|^HOOKS=.*|HOOKS=(base udev autodetect modconf block mdadm_udev lvm2 netconf dropbear encryptssh filesystems keyboard fsck)|' \
  /etc/mkinitcpio.conf

echo "HOOKS line is now:"
grep '^HOOKS=' /etc/mkinitcpio.conf

banner "done"
cat <<EOF
Next steps:
  1. Activate Hetzner Rescue in the Robot, then reboot the server.
  2. From your client:  hal connect rescue <host>
  3. Inside rescue:     hal encrypt-root <host>
  4. After that:        hal install-grub <host>
EOF
