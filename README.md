# Arch Linux with LUKS and btrfs on a Hetzner server

A small Python CLI (`hal`) that wraps every step of installing, encrypting, and
maintaining an [Arch Linux](https://www.archlinux.de/) server on
[Hetzner](https://www.hetzner.com/) Dedicated hardware with software RAID,
[LUKS](https://wiki.archlinux.org/index.php/Dm-crypt) full-disk encryption,
[btrfs](https://en.wikipedia.org/wiki/Btrfs) on top of LVM, and remote unlock
via [dropbear](https://wiki.archlinux.org/title/Dm-crypt/Specialties#busybox-based_initramfs_(built_with_mkinitcpio))
in the initramfs.

**Author:** Kevin Veen-Birkenbach &lt;[kevin@veen.world](mailto:kevin@veen.world)&gt; — [veen.world](https://veen.world)  
**License:** MIT — see [LICENSE](./LICENSE)

## Install the CLI

```bash
make install   # → pip install --user -e .
hal --help
```

After install, every step below is a single `hal` subcommand.

## Subcommand reference

Run `hal --help`, `hal <group> --help`, or `hal <group> <target> --help` for the live reference.

### Top-level

| Command | What it does |
|---|---|
| `hal status <host>` | Ping + port scan + SSH banner. No login. |
| `hal diagnose <host>` | Rescue → chroot, runs a fixed inspection script. Pipe with `tee` to save. |
| `hal unlock <host>` | Send the LUKS passphrase from the keyring to dropbear (`cryptroot-unlock`). |
| `hal forget <host>` | Clear the cached LUKS passphrase from libsecret. |

### `hal connect <target> <host> [cmd]`

Open a shell, or run `cmd` non-interactively.

| Target | Where it goes |
|---|---|
| `rescue` | Hetzner Rescue OS |
| `server` | Booted Arch system |
| `chroot` | Rescue → chroot of installed Arch (LUKS-unlocks + mounts first) |

### `hal setup <target> <host>` — one-time install operations

| Target | What it does |
|---|---|
| `image --autosetup PATH` | In rescue: upload autosetup, run `installimage`. **Destructive.** |
| `dropbear` | Booted Arch: install dropbear + mkinitcpio plugins, copy authorized_keys, patch HOOKS. |
| `grub` | Rescue → chroot: install grub package, write LUKS-aware `/etc/default/grub`, grub-install on every boot disk. |
| `encrypt-root` | Rescue: LUKS-encrypt `/dev/md1`, preserve data via `/oldroot` copy. **Destructive on `/dev/md1`. Confirms before format.** |

### `hal fix <target> <host>` — recovery + maintenance operations

| Target | What it does |
|---|---|
| `boot` | Patch `PermitRootLogin`, enable persistent journald. |
| `network` | Rewrite `.network` files to match by MACAddress= instead of interface name. |
| `grub` | Refresh Stage1 + core.img in MBR (Arch doesn't do this automatically after grub upgrades). |
| `kernel` | Roll the `linux` package back to the previous version (cache or archive.archlinux.org). |
| `static-ip` | Replace `ip=dhcp` in `/etc/default/grub` with a static cmdline IP derived from `/etc/systemd/network/*.network`. |
| `upgrade` | Full `pacman -Syyu` + initramfs rebuild + grub-install on every boot disk. |
| `expand-fs` | On booted Arch: `lvresize -l +100%FREE /dev/vg0/root && btrfs filesystem resize max /`. |

The LUKS passphrase is prompted (hidden) on first use and cached in the libsecret keyring per host — subsequent runs against the same host don't prompt.

## Setup flow

Each section is a small handful of `hal` commands. Click into the corresponding
table row above for what each one actually does.

Set the server IP/hostname once per shell — every block below uses `$SERVER`:

```bash
export SERVER=your_server_ip   # e.g. 46.4.224.77 or boot.echoserver
```

### 1. Install Arch via installimage

```bash
hal connect rescue "$SERVER"                              # verify rescue is up
hal setup image "$SERVER" --autosetup autosetup           # see autosetup.example
hal connect rescue "$SERVER" reboot
```

Tip: copy `autosetup.example` to `autosetup`, edit `DRIVE1`/`DRIVE2`/`HOSTNAME`,
then run `setup image`.

### 2. Boot Arch, install the dropbear stack

```bash
hal connect server "$SERVER"                              # verify SSH works
hal connect server "$SERVER" pacman -Syyu                 # bring system current
hal setup dropbear "$SERVER"                              # dropbear + mkinitcpio plugins + HOOKS
```

### 3. Convert root to LUKS

Activate Rescue in the Hetzner Robot UI, then:

```bash
hal connect server "$SERVER" reboot                       # boots back into rescue
hal connect rescue "$SERVER"                              # verify rescue is up
hal setup encrypt-root "$SERVER"                          # LUKS conversion — DESTRUCTIVE
hal setup grub "$SERVER"                                  # initial GRUB for LUKS boot
hal fix static-ip "$SERVER"                               # static initramfs IP — Hetzner DHCP is fragile
```

Deactivate Rescue in the Hetzner Robot UI, then:

```bash
hal connect rescue "$SERVER" reboot                       # final reboot into encrypted system
```

### 4. Day-to-day use

After every reboot the system blocks at dropbear in initramfs waiting for the
LUKS passphrase. From your client:

```bash
hal status "$SERVER"                                      # wait for dropbear / sshd
hal unlock "$SERVER"                                      # send passphrase to dropbear
hal connect server "$SERVER"                              # normal SSH after unlock
```

### 5. Expand the root filesystem later

If the autosetup gave you a small root LV and the rest is free LVM space:

```bash
hal fix expand-fs "$SERVER"
```

## Debugging an unresponsive server

The server isn't booting / SSH never comes up:

```bash
# 1. Reach the server's chroot
hal connect rescue "$SERVER"                              # via Hetzner Robot → Rescue first
hal diagnose "$SERVER" | tee "diag-$(date +%F-%H%M).log"

# 2. Apply best-guess fixes in roughly this order
hal fix boot "$SERVER"                                    # sshd config + journald
hal fix network "$SERVER"                                 # interface naming drift
hal fix grub "$SERVER"                                    # stale MBR after grub upgrades
hal fix static-ip "$SERVER"                               # DHCP-in-initramfs fragility

# 3. Last-resort kernel rollback (if a kernel bump is the suspect)
hal fix kernel "$SERVER"

# 4. Or, after fixing whatever was broken, upgrade everything cleanly
hal fix upgrade "$SERVER"
```

Every `hal` chroot command makes its own backups (`<file>.hal-backup`)
before mutating anything, so individual fixes can be reverted by hand.

## Sources

* http://daemons-point.com/blog/2019/10/20/hetzner-verschluesselt/
* https://www.howtoforge.com/using-the-btrfs-filesystem-with-raid1-with-ubuntu-12.10-on-a-hetzner-server
* https://code.trafficking.agency/arch-linux-remote-unlock-root-volume-with-mdraid-and-dmcrypt.html
* https://wiki.archlinux.org/index.php/Dm-crypt/Specialties#Remote_unlocking_(hooks:_netconf,_dropbear,_tinyssh,_ppp)
* https://gist.github.com/pezz/5310082
