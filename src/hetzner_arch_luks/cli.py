"""Command-line interface for the hetzner-arch-luks helpers.

Top-level structure:

    hal status HOST
    hal diagnose HOST
    hal unlock HOST
    hal forget HOST

    hal connect {rescue,chroot,server} HOST [CMD...]
    hal setup   {image,dropbear,grub,encrypt-root} HOST [...]
    hal fix     {boot,network,grub,kernel,static-ip,upgrade,expand-fs} HOST

For commands that need the LUKS passphrase, the prompt happens *first*,
before any network IO. The passphrase is cached per-host in the libsecret
keyring so subsequent runs against the same host don't prompt.
"""
from __future__ import annotations

import argparse
import sys

from . import __version__, probe, remote

_AUTHOR = "Kevin Veen-Birkenbach <kevin@veen.world>"
_HOMEPAGE = "https://veen.world"


def _add_passphrase_flag(p: argparse.ArgumentParser) -> None:
    p.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )


def _add_host(p: argparse.ArgumentParser) -> None:
    p.add_argument("host")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="hal",
        description=(
            "End-to-end CLI for installing, encrypting, debugging and maintaining "
            "an Arch Linux server on Hetzner Dedicated hardware with software RAID, "
            "LUKS full-disk encryption, btrfs on LVM, and remote unlock via dropbear "
            "in the initramfs."
        ),
        epilog=f"Author: {_AUTHOR} — {_HOMEPAGE}    License: MIT",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--version",
        action="version",
        version=(
            f"hal {__version__}\n"
            f"Author:   {_AUTHOR}\n"
            f"Homepage: {_HOMEPAGE}\n"
            f"License:  MIT"
        ),
    )

    sub = parser.add_subparsers(dest="cmd", required=True, metavar="COMMAND")

    # -------------------- Top-level commands --------------------

    p = sub.add_parser(
        "status",
        help="Probe reachability of a host (ping + ports + SSH banner). No login.",
    )
    _add_host(p)

    p = sub.add_parser(
        "diagnose",
        help="Collect a fixed inspection report from inside the installed system via rescue.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = sub.add_parser(
        "unlock",
        help="Send the LUKS passphrase from the keyring to dropbear (cryptroot-unlock). Use after a reboot.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = sub.add_parser(
        "forget",
        help="Drop the cached LUKS passphrase for a host from the libsecret keyring.",
    )
    _add_host(p)

    # -------------------- `connect` group --------------------

    p_connect = sub.add_parser(
        "connect",
        help="Open a remote shell on rescue / chroot / server, or run a one-off command there.",
    )
    p_connect_sub = p_connect.add_subparsers(
        dest="target", required=True, metavar="TARGET"
    )

    p = p_connect_sub.add_parser(
        "rescue",
        help="SSH into the Hetzner rescue system. Append a command for non-interactive use.",
    )
    _add_host(p)
    p.add_argument(
        "command", nargs=argparse.REMAINDER,
        help="Optional command + args to run on the rescue instead of an interactive shell.",
    )

    p = p_connect_sub.add_parser(
        "chroot",
        help="Unlock LUKS via rescue, mount, and drop into `chroot /mnt /bin/bash`. Append a command for non-interactive use.",
    )
    _add_host(p)
    _add_passphrase_flag(p)
    p.add_argument(
        "command", nargs=argparse.REMAINDER,
        help="Optional command + args to run inside the chroot instead of an interactive shell.",
    )

    p = p_connect_sub.add_parser(
        "server",
        help="SSH into the booted Arch system. Append a command for non-interactive use.",
    )
    _add_host(p)
    p.add_argument(
        "command", nargs=argparse.REMAINDER,
        help="Optional command + args to run on the server instead of an interactive shell.",
    )

    # -------------------- `setup` group (one-time install) --------------------

    p_setup = sub.add_parser(
        "setup",
        help="One-time install operations: image / dropbear / grub / encrypt-root.",
    )
    p_setup_sub = p_setup.add_subparsers(
        dest="target", required=True, metavar="TARGET"
    )

    p = p_setup_sub.add_parser(
        "image",
        help="In rescue: upload an autosetup file and run `installimage`. DESTRUCTIVE.",
    )
    _add_host(p)
    p.add_argument(
        "--autosetup", required=True,
        help="Path to a local autosetup config file (uploaded to /autosetup on rescue).",
    )

    p = p_setup_sub.add_parser(
        "dropbear",
        help="On the booted system: install dropbear + mkinitcpio plugins, copy authorized_keys, patch HOOKS. MUTATES.",
    )
    _add_host(p)

    p = p_setup_sub.add_parser(
        "grub",
        help="In chroot (initial install): install grub package, write LUKS-aware /etc/default/grub, grub-install on every boot disk. MUTATES.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = p_setup_sub.add_parser(
        "encrypt-root",
        help="In rescue: full LUKS conversion of an installed Arch (sections 4.4–4.15). DESTRUCTIVE — confirms before format.",
    )
    _add_host(p)

    # -------------------- `fix` group (recovery operations) --------------------

    p_fix = sub.add_parser(
        "fix",
        help="Recovery + maintenance operations: boot / network / grub / kernel / static-ip / upgrade / expand-fs.",
    )
    p_fix_sub = p_fix.add_subparsers(
        dest="target", required=True, metavar="TARGET"
    )

    p = p_fix_sub.add_parser(
        "boot",
        help="In chroot: patch PermitRootLogin to prohibit-password, enable persistent journald. MUTATES.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = p_fix_sub.add_parser(
        "network",
        help="In chroot: rewrite /etc/systemd/network/*.network to match by MACAddress= instead of interface name. MUTATES.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = p_fix_sub.add_parser(
        "grub",
        help="In chroot: re-run grub-install on every disk backing /boot. MUTATES the MBR.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = p_fix_sub.add_parser(
        "kernel",
        help="In chroot: roll the `linux` package back to the previous version (cache or archive.archlinux.org). MUTATES.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = p_fix_sub.add_parser(
        "static-ip",
        help="In chroot: replace `ip=dhcp` in /etc/default/grub with a static kernel-cmdline IP derived from the .network file. MUTATES.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = p_fix_sub.add_parser(
        "upgrade",
        help="In chroot: full `pacman -Syyu` + rebuild initramfs + grub-install on every boot disk. MUTATES.",
    )
    _add_host(p)
    _add_passphrase_flag(p)

    p = p_fix_sub.add_parser(
        "expand-fs",
        help="On the booted system: `lvresize -l +100%%FREE /dev/vg0/root && btrfs filesystem resize max /`. MUTATES.",
    )
    _add_host(p)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    pp = not getattr(args, "no_passphrase_prompt", False)

    # Top-level
    if args.cmd == "status":
        return probe.status(args.host)
    if args.cmd == "diagnose":
        return remote.diagnose(args.host, ask_passphrase=pp)
    if args.cmd == "unlock":
        return remote.unlock(args.host, ask_passphrase=pp)
    if args.cmd == "forget":
        return remote.forget_passphrase(args.host)

    # connect group
    if args.cmd == "connect":
        cmd_list = getattr(args, "command", None) or None
        if args.target == "rescue":
            return remote.connect_rescue(args.host, command=cmd_list)
        if args.target == "chroot":
            return remote.connect_chroot(args.host, ask_passphrase=pp, command=cmd_list)
        if args.target == "server":
            return remote.connect_server(args.host, command=cmd_list)

    # setup group
    if args.cmd == "setup":
        if args.target == "image":
            return remote.install_image(args.host, args.autosetup)
        if args.target == "dropbear":
            return remote.setup_dropbear(args.host)
        if args.target == "grub":
            return remote.install_grub(args.host, ask_passphrase=pp)
        if args.target == "encrypt-root":
            return remote.encrypt_root(args.host)

    # fix group
    if args.cmd == "fix":
        if args.target == "boot":
            return remote.fix_boot(args.host, ask_passphrase=pp)
        if args.target == "network":
            return remote.fix_network(args.host, ask_passphrase=pp)
        if args.target == "grub":
            return remote.reinstall_grub(args.host, ask_passphrase=pp)
        if args.target == "kernel":
            return remote.downgrade_kernel(args.host, ask_passphrase=pp)
        if args.target == "static-ip":
            return remote.use_static_ip(args.host, ask_passphrase=pp)
        if args.target == "upgrade":
            return remote.upgrade_system(args.host, ask_passphrase=pp)
        if args.target == "expand-fs":
            return remote.expand_fs(args.host)

    return 2


if __name__ == "__main__":
    sys.exit(main())
