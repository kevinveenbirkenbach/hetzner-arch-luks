"""Command-line interface for the hetzner-arch-luks helpers.

Entry point:  hal <subcommand> <host>

Subcommands:
    status                  client-side reachability probe (no login)
    connect rescue <host>   SSH into the rescue system
    connect chroot <host>   LUKS unlock + mount + interactive chroot shell
    diagnose <host>         LUKS unlock + mount + collect diagnostics

For commands that need the LUKS passphrase, the prompt happens *first*, before
any network IO — so you can type the passphrase, walk away, and the rest runs
unattended.
"""
from __future__ import annotations

import argparse
import sys

from . import probe, remote


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="hal",
        description="Helper CLI for the hetzner-arch-luks workflow.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_status = sub.add_parser(
        "status",
        help="Probe reachability of a host (ping + ports + SSH banner). No login.",
    )
    p_status.add_argument("host")

    p_connect = sub.add_parser(
        "connect",
        help="Open an interactive remote shell.",
    )
    p_connect_sub = p_connect.add_subparsers(dest="target", required=True)

    p_rescue = p_connect_sub.add_parser(
        "rescue",
        help="SSH into the Hetzner rescue system (waits for port 22 to come up). "
             "Pass extra args after the host to run them non-interactively.",
    )
    p_rescue.add_argument("host")
    p_rescue.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Optional command + args to run on the rescue instead of opening "
             "an interactive shell. Example: hal connect rescue HOST reboot",
    )

    p_chroot = p_connect_sub.add_parser(
        "chroot",
        help="Unlock LUKS via rescue, mount, and drop into chroot /mnt /bin/bash. "
             "Pass extra args after the host to run them inside the chroot.",
    )
    p_chroot.add_argument("host")
    p_chroot.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )
    p_chroot.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Optional command + args to run inside the chroot instead of "
             "opening an interactive shell. Example: hal connect chroot HOST pacman -Q linux",
    )

    p_diag = sub.add_parser(
        "diagnose",
        help="Collect diagnostics from inside the installed system via rescue.",
    )
    p_diag.add_argument("host")
    p_diag.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )

    p_fix = sub.add_parser(
        "fix-boot",
        help="Apply boot/SSH fixes inside the chroot. MUTATES the installed system.",
    )
    p_fix.add_argument("host")
    p_fix.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )

    p_fixnet = sub.add_parser(
        "fix-network",
        help="Rewrite systemd-networkd .network files to use MACAddress= match. MUTATES.",
    )
    p_fixnet.add_argument("host")
    p_fixnet.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )

    p_dk = sub.add_parser(
        "downgrade-kernel",
        help="Roll the linux package back to the previous cached version. MUTATES. "
             "Use after a kernel-bump pacman -Syu made the system unbootable.",
    )
    p_dk.add_argument("host")
    p_dk.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )

    p_fp = sub.add_parser(
        "forget-passphrase",
        help="Drop the cached LUKS passphrase for a host from the libsecret keyring.",
    )
    p_fp.add_argument("host")

    p_rg = sub.add_parser(
        "reinstall-grub",
        help="Re-run grub-install on every disk backing /boot. MUTATES the MBR. "
             "Use after a grub-package upgrade that didn't refresh the bootloader.",
    )
    p_rg.add_argument("host")
    p_rg.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )

    p_di = sub.add_parser(
        "downgrade-initramfs",
        help="Downgrade mkinitcpio + dropbear + cryptsetup + mdadm + lvm2 to the "
             "version before the last pacman -Syu, then rebuild initramfs. MUTATES.",
    )
    p_di.add_argument("host")
    p_di.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )

    p_si = sub.add_parser(
        "use-static-ip",
        help="Replace ip=dhcp in /etc/default/grub with a static kernel-cmdline "
             "network spec (derived from /etc/systemd/network/*.network). MUTATES.",
    )
    p_si.add_argument("host")
    p_si.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )

    p_us = sub.add_parser(
        "upgrade-system",
        help="Full pacman -Syyu + initramfs rebuild + grub-install on every boot disk "
             "+ grub.cfg regen, all in one chroot session. Uses --disable-sandbox "
             "to work around the Hetzner Rescue kernel's missing Landlock. MUTATES.",
    )
    p_us.add_argument("host")
    p_us.add_argument(
        "--no-passphrase-prompt",
        action="store_true",
        help="Skip the early LUKS prompt (use when LUKS is already open from a prior run).",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    if args.cmd == "status":
        return probe.status(args.host)
    if args.cmd == "connect" and args.target == "rescue":
        return remote.connect_rescue(args.host, command=args.command or None)
    if args.cmd == "connect" and args.target == "chroot":
        return remote.connect_chroot(
            args.host,
            ask_passphrase=not args.no_passphrase_prompt,
            command=args.command or None,
        )
    if args.cmd == "diagnose":
        return remote.diagnose(args.host, ask_passphrase=not args.no_passphrase_prompt)
    if args.cmd == "fix-boot":
        return remote.fix_boot(args.host, ask_passphrase=not args.no_passphrase_prompt)
    if args.cmd == "fix-network":
        return remote.fix_network(args.host, ask_passphrase=not args.no_passphrase_prompt)
    if args.cmd == "downgrade-kernel":
        return remote.downgrade_kernel(args.host, ask_passphrase=not args.no_passphrase_prompt)
    if args.cmd == "forget-passphrase":
        return remote.forget_passphrase(args.host)
    if args.cmd == "reinstall-grub":
        return remote.reinstall_grub(args.host, ask_passphrase=not args.no_passphrase_prompt)
    if args.cmd == "downgrade-initramfs":
        return remote.downgrade_initramfs(args.host, ask_passphrase=not args.no_passphrase_prompt)
    if args.cmd == "use-static-ip":
        return remote.use_static_ip(args.host, ask_passphrase=not args.no_passphrase_prompt)
    if args.cmd == "upgrade-system":
        return remote.upgrade_system(args.host, ask_passphrase=not args.no_passphrase_prompt)

    return 2


if __name__ == "__main__":
    sys.exit(main())
