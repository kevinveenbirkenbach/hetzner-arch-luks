"""Orchestrates the rescue / chroot / diagnose flows over an SshSession.

Key UX choices:
  - The LUKS passphrase is prompted *before* we touch the network, so the
    user enters it once and can step away while the rest runs.
  - On first prompt the passphrase is cached in the libsecret keyring
    (GNOME Keyring / KWallet via secret-tool) so subsequent runs against
    the same host skip the prompt entirely.
"""
from __future__ import annotations

import getpass
import importlib.resources
import shlex
import shutil
import subprocess
import sys

from .ssh import SshSession, wait_for_port


# Pre-LUKS step: assemble the RAID arrays. Idempotent (mdadm returns non-zero
# when arrays are already assembled — we swallow that).
_ASSEMBLE = "mdadm --assemble --scan 2>/dev/null || true"

# Post-LUKS step: activate LVM, mount root + boot, bind /dev /proc /sys /run.
# Idempotent: every mount is guarded with `mountpoint -q`.
_MOUNT = r"""
set -e
vgchange -ay >/dev/null
if ! mountpoint -q /mnt; then
  mount /dev/vg0/root /mnt
  mkdir -p /mnt/boot
  mount /dev/md0 /mnt/boot
fi
for d in dev proc sys run; do
  mountpoint -q "/mnt/$d" || mount --rbind "/$d" "/mnt/$d"
done
"""

# Schema for libsecret entries:
#   service = hetzner-arch-luks
#   host    = <host>
_KEYRING_SERVICE = "hetzner-arch-luks"


# ---- keyring helpers (libsecret via secret-tool) ---------------------------


def _have_secret_tool() -> bool:
    return shutil.which("secret-tool") is not None


def _keyring_load(host: str) -> str | None:
    """Look up the cached LUKS passphrase for `host`. None if not stored."""
    if not _have_secret_tool():
        return None
    r = subprocess.run(
        ["secret-tool", "lookup", "service", _KEYRING_SERVICE, "host", host],
        capture_output=True, text=True,
    )
    if r.returncode == 0 and r.stdout:
        # secret-tool prints the secret raw, without trailing newline
        return r.stdout
    return None


def _keyring_store(host: str, passphrase: str) -> None:
    """Persist `passphrase` in libsecret under (service, host)."""
    if not _have_secret_tool():
        return
    label = f"hetzner-arch-luks LUKS passphrase for {host}"
    subprocess.run(
        [
            "secret-tool", "store", "--label", label,
            "service", _KEYRING_SERVICE, "host", host,
        ],
        input=passphrase, text=True, check=False,
    )


def _keyring_clear(host: str) -> bool:
    """Drop the cached passphrase for `host`. Returns True if anything was deleted."""
    if not _have_secret_tool():
        return False
    if _keyring_load(host) is None:
        return False
    subprocess.run(
        ["secret-tool", "clear", "service", _KEYRING_SERVICE, "host", host],
        check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return True


# ---- passphrase prompt -----------------------------------------------------


def _prompt_passphrase(host: str, *, force_prompt: bool = False) -> str:
    """Get the LUKS passphrase for `host`.

    Order:
      1. Try the libsecret keyring (skipped if force_prompt=True or
         secret-tool isn't installed).
      2. Hidden prompt via getpass. On success, store to the keyring for
         next time.

    Empty input aborts the whole command.
    """
    if not force_prompt:
        cached = _keyring_load(host)
        if cached:
            print(f"(passphrase from keyring for {host})", file=sys.stderr)
            return cached
    p = getpass.getpass(f"LUKS passphrase for {host}: ")
    if not p:
        print("Empty passphrase — aborting.", file=sys.stderr)
        sys.exit(1)
    _keyring_store(host, p)
    return p


# ---- session helpers -------------------------------------------------------


def _wait_rescue(host: str, timeout: int = 300) -> None:
    print(f"==> Waiting for {host}:22 ...")
    if not wait_for_port(host, 22, timeout=timeout):
        print(f"Timeout: {host}:22 not reachable after {timeout}s", file=sys.stderr)
        sys.exit(1)


def _luks_is_open(ssh: SshSession) -> bool:
    r = ssh.run("test -e /dev/mapper/cryptroot", check=False, capture=True)
    return r.returncode == 0


def _ensure_unlocked(ssh: SshSession, host: str, passphrase: str | None) -> None:
    """Open LUKS if needed. Retries once with a fresh prompt if the cached
    passphrase from the keyring is rejected by cryptsetup.

    cryptsetup reads the passphrase from stdin (via --key-file=-) and stops
    at EOF. We send raw bytes with no trailing newline.
    """
    if _luks_is_open(ssh):
        print("==> LUKS already open.")
        return
    if passphrase is None:
        passphrase = _prompt_passphrase(host)
    print("==> Opening LUKS ...")
    try:
        ssh.run(
            "cryptsetup luksOpen --key-file=- /dev/md1 cryptroot",
            input_=passphrase.encode(),
        )
    except subprocess.CalledProcessError:
        # Most likely: wrong passphrase. If we got it from the keyring,
        # clear the bad entry and re-prompt once.
        if _keyring_clear(host):
            print(
                "==> cryptsetup rejected the cached passphrase. Cleared keyring; re-prompting.",
                file=sys.stderr,
            )
            passphrase = _prompt_passphrase(host, force_prompt=True)
            ssh.run(
                "cryptsetup luksOpen --key-file=- /dev/md1 cryptroot",
                input_=passphrase.encode(),
            )
        else:
            raise


def _setup(ssh: SshSession, host: str, passphrase: str | None) -> None:
    """Full sequence: assemble + LUKS + LVM + mount + binds."""
    print("==> Assembling RAID ...")
    ssh.run(_ASSEMBLE)
    _ensure_unlocked(ssh, host, passphrase)
    print("==> Activating LVM + mounting + binding ...")
    ssh.run(_MOUNT)


# ---- public entry points (called by cli.py) --------------------------------


def _connect_simple(host: str, label: str, command: list[str] | None) -> int:
    """Shared body of `connect_rescue` and `connect_server` — wait for SSH,
    then either drop into an interactive shell or run `command` and print.
    """
    _wait_rescue(host)
    with SshSession(host) as ssh:
        if command:
            cmd_str = " ".join(shlex.quote(c) for c in command)
            print(f"==> Running on {label}: {cmd_str}")
            ssh.run(cmd_str, check=False)
        else:
            print(f"==> Connected to {label}. Type 'exit' to leave.")
            ssh.run("exec bash -l", tty=True, check=False)
    return 0


def connect_rescue(host: str, *, command: list[str] | None = None) -> int:
    """Wait for rescue to come up, then open a shell or run `command`."""
    return _connect_simple(host, "rescue", command)


def connect_server(host: str, *, command: list[str] | None = None) -> int:
    """Wait for the booted Arch system to come up, then open a shell or
    run `command`. Same SSH plumbing as `connect_rescue`; named differently
    for clarity in the docs."""
    return _connect_simple(host, "server", command)


def connect_chroot(
    host: str,
    *,
    ask_passphrase: bool = True,
    command: list[str] | None = None,
) -> int:
    """Unlock LUKS via rescue, mount, then either open an interactive chroot
    shell or run `command` inside the chroot non-interactively and print
    its output."""
    passphrase = _prompt_passphrase(host) if ask_passphrase else None
    _wait_rescue(host)
    with SshSession(host) as ssh:
        _setup(ssh, host, passphrase)
        if command:
            # Pipe the command into chroot's bash via stdin — avoids all the
            # quoting layers of `bash -c '<cmd>'` and is identical to how the
            # diagnose/fix scripts are streamed in.
            cmd_str = " ".join(shlex.quote(c) for c in command)
            print(f"==> Running in chroot: {cmd_str}")
            ssh.run("chroot /mnt /bin/bash", input_=(cmd_str + "\n").encode())
        else:
            print("==> Entering chroot. Type 'exit' to leave.")
            ssh.run("chroot /mnt /bin/bash", tty=True, check=False)
    return 0


def diagnose(host: str, *, ask_passphrase: bool = True) -> int:
    """Unlock + mount + run the chrooted diagnose script. Output goes to stdout."""
    return _run_chroot_script(host, "diagnose/inside.sh", "diagnose", ask_passphrase)


def fix_boot(host: str, *, ask_passphrase: bool = True) -> int:
    """Unlock + mount + apply boot/SSH fixes inside chroot. MUTATES the system."""
    return _run_chroot_script(host, "fix/boot.sh", "fix-boot", ask_passphrase)


def fix_network(host: str, *, ask_passphrase: bool = True) -> int:
    """Unlock + mount + rewrite .network files to use MACAddress= match. MUTATES."""
    return _run_chroot_script(host, "fix/network.sh", "fix-network", ask_passphrase)


def downgrade_kernel(host: str, *, ask_passphrase: bool = True) -> int:
    """Unlock + mount + downgrade linux to the previous cached version. MUTATES."""
    return _run_chroot_script(host, "fix/kernel.sh", "downgrade-kernel", ask_passphrase)


def reinstall_grub(host: str, *, ask_passphrase: bool = True) -> int:
    """Unlock + mount + grub-install on every disk backing /boot's RAID. MUTATES MBR."""
    return _run_chroot_script(host, "fix/grub.sh", "reinstall-grub", ask_passphrase)


def use_static_ip(host: str, *, ask_passphrase: bool = True) -> int:
    """Replace ip=dhcp in /etc/default/grub with a static spec parsed from
    the existing systemd-networkd .network file. Regenerates grub.cfg. MUTATES."""
    return _run_chroot_script(host, "fix/static_ip.sh", "use-static-ip", ask_passphrase)


def upgrade_system(host: str, *, ask_passphrase: bool = True) -> int:
    """Unlock + mount + full `pacman -Syu` + rebuild initramfs + refresh GRUB
    (config + MBR on all boot disks). Uses --disable-sandbox because the
    Hetzner Rescue kernel lacks Landlock. MUTATES."""
    return _run_chroot_script(host, "maintain/upgrade.sh", "upgrade-system", ask_passphrase)


def unlock(host: str, *, ask_passphrase: bool = True) -> int:
    """Pipe the LUKS passphrase to `cryptroot-unlock` on the dropbear that
    is listening from initramfs. Use after a reboot, before the main sshd
    is reachable. Uses a throwaway known_hosts to avoid host-key conflicts
    between the dropbear and the real sshd (different host keys, same port).
    """
    passphrase = _prompt_passphrase(host) if ask_passphrase else None
    if passphrase is None:
        print("Need a passphrase to send to cryptroot-unlock.", file=sys.stderr)
        return 1
    _wait_rescue(host)  # really just "wait for port 22"
    print(f"==> Sending passphrase to dropbear on {host} ...")
    cmd = [
        "ssh",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10",
        f"root@{host}",
        "cryptroot-unlock",
    ]
    r = subprocess.run(cmd, input=(passphrase + "\n").encode(), check=False)
    if r.returncode == 0:
        print("==> Passphrase accepted; system continues boot.")
    else:
        print(f"==> ssh/cryptroot-unlock exited with code {r.returncode}",
              file=sys.stderr)
    return r.returncode


def expand_fs(host: str) -> int:
    """Run `lvresize -l +100%FREE /dev/vg0/root && btrfs filesystem resize max /`
    on the booted system. No LUKS passphrase needed — server is already up."""
    _wait_rescue(host)
    with SshSession(host) as ssh:
        print("==> Expanding LVM root + btrfs filesystem ...")
        ssh.run("lvresize -l +100%FREE /dev/vg0/root && btrfs filesystem resize max /")
    return 0


def setup_dropbear(host: str) -> int:
    """Install dropbear + supporting packages, configure SSH keys, patch
    /etc/mkinitcpio.conf HOOKS. Runs on the booted system. MUTATES."""
    inside = (
        importlib.resources
        .files("hetzner_arch_luks")
        .joinpath("resources/setup/dropbear.sh")
        .read_bytes()
    )
    _wait_rescue(host)
    with SshSession(host) as ssh:
        print("==> Running setup-dropbear on the booted system ...")
        ssh.run("bash -s", input_=inside)
    return 0


def install_grub(host: str, *, ask_passphrase: bool = True) -> int:
    """Inside chroot: install grub package, write /etc/default/grub for
    LUKS-encrypted root, grub-install on every boot disk, grub-mkconfig.
    Used during the initial encryption setup. MUTATES."""
    return _run_chroot_script(host, "setup/grub.sh", "install-grub", ask_passphrase)


def install_image(host: str, autosetup_path: str) -> int:
    """Upload an autosetup config to the rescue and run `installimage`.
    DESTRUCTIVE — formats the disks per the autosetup contents."""
    import pathlib
    p = pathlib.Path(autosetup_path)
    if not p.exists():
        print(f"autosetup file not found: {autosetup_path}", file=sys.stderr)
        return 1
    content = p.read_bytes()
    _wait_rescue(host)
    with SshSession(host) as ssh:
        print(f"==> Uploading {autosetup_path} → /autosetup on rescue ...")
        ssh.run("cat > /autosetup", input_=content)
        print("==> Running installimage (DESTRUCTIVE — this formats the disks!)")
        ssh.run("installimage", tty=True)
    return 0


def encrypt_root(host: str) -> int:
    """In rescue (NOT chroot): re-format /dev/md1 with LUKS, preserve the
    installed root by copying through /oldroot, then mkinitcpio inside chroot.

    Interactive: cryptsetup prompts for the new LUKS passphrase via the rescue
    TTY. We upload the script to /root/_encrypt_root.sh and execute it with
    a TTY allocated so cryptsetup's prompts work. DESTRUCTIVE on /dev/md1."""
    content = (
        importlib.resources
        .files("hetzner_arch_luks")
        .joinpath("resources/setup/encrypt_root.sh")
        .read_bytes()
    )
    _wait_rescue(host)
    with SshSession(host) as ssh:
        print("==> Uploading encrypt-root script to rescue:/root/_encrypt_root.sh")
        ssh.run("cat > /root/_encrypt_root.sh && chmod +x /root/_encrypt_root.sh",
                input_=content)
        print("==> Running encrypt-root (interactive — answer cryptsetup prompts)")
        ssh.run("/root/_encrypt_root.sh", tty=True, check=False)
        ssh.run("rm -f /root/_encrypt_root.sh", check=False)
    return 0


def forget_passphrase(host: str) -> int:
    """Drop the stored LUKS passphrase for `host` from the libsecret keyring."""
    if not _have_secret_tool():
        print("secret-tool not installed — no keyring backend; nothing to clear.",
              file=sys.stderr)
        return 1
    if _keyring_clear(host):
        print(f"Cleared cached LUKS passphrase for {host}.")
        return 0
    print(f"No cached LUKS passphrase for {host}.")
    return 0


def _run_chroot_script(host: str, resource: str, label: str, ask_passphrase: bool) -> int:
    """Shared driver: unlock + mount + pipe a packaged script into chrooted bash.

    The script is streamed as stdin to `chroot /mnt /bin/bash`; bash reads its
    program from stdin, so it runs inside the chroot without leaving any file
    on the target.
    """
    passphrase = _prompt_passphrase(host) if ask_passphrase else None
    _wait_rescue(host)
    inside = (
        importlib.resources
        .files("hetzner_arch_luks")
        .joinpath(f"resources/{resource}")
        .read_bytes()
    )
    with SshSession(host) as ssh:
        _setup(ssh, host, passphrase)
        print(f"==> Running {label} inside chroot ...")
        ssh.run("chroot /mnt /bin/bash", input_=inside)
    return 0
