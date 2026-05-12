# Arch Linux with LUKS and btrfs on a Hetzner server

## Software
This guide shows how to set up the following software composition:
* [Arch Linux](https://www.archlinux.de/)
* [btrfs](https://en.wikipedia.org/wiki/Btrfs)
* [LUKS](https://wiki.archlinux.org/index.php/Dm-crypt)

## Requirements
Written for a [Dedicated](https://de.wikipedia.org/wiki/Server#Dedizierte_Server) [Hetzner](https://www.hetzner.com/) server with the following hardware specifications:
```
CPU1: Intel(R) Core(TM) i7-2600 CPU @ 3.40GHz (Cores 8)
Memory:  15973 MB
Disk /dev/sda: 3000 GB (=> 2794 GiB)
Disk /dev/sdb: 3000 GB (=> 2794 GiB)
Total capacity 5589 GiB with 2 Disks
```

## Legend
The following symbols show in which environment the code is executed:
* :computer: Client
* :ambulance: [Hetzner Rescue System](https://wiki.hetzner.de/index.php/Hetzner_Rescue-System/en)
* :ghost: Chroot from Rescue System into Arch
* :minidisc: Arch OS

## CLI helper (`hal`)
This repo ships a small Python CLI (`hal`) that wraps the recurring SSH / LUKS / chroot dances. Install it once on your client:

```bash
pip install --user -e .
```

After that, `hal` is on your `$PATH`. Subcommands used throughout the guide:

| Command | What it does |
|---|---|
| `hal status <host>` | Probe reachability (ping, ports 22/222, SSH banner). No login. |
| `hal connect rescue <host>` | Wait for rescue, drop known_hosts entry, SSH in as root. |
| `hal connect chroot <host>` | Prompt LUKS passphrase **first** (hidden), then via rescue: assemble RAID → unlock LUKS → mount → drop into `chroot /mnt /bin/bash`. |
| `hal diagnose <host>` | Same setup as `connect chroot`, then runs a fixed diagnostic script inside the chroot and prints the report to stdout. |

The passphrase prompt happens *before* the SSH connection is established, so you can type it once, walk away, and the rest runs unattended.

## Guide
### 1. Configure and Install Image
#### 1.1 Login to Hetzner Rescue System
:computer: :
```bash
hal connect rescue your_server_ip
```
#### 1.2 Create the /autosetup

:ambulance: :

```bash
nano /autosetup
```

Save the following content into this file:

```
##  Hetzner Online GmbH - installimage - config

DRIVE1 /dev/sda
DRIVE2 /dev/sdb

##  SOFTWARE RAID:
## activate software RAID?  < 0 | 1 >
SWRAID 1

## Choose the level for the software RAID < 0 | 1 | 10 >
SWRAIDLEVEL 1

##  BOOTLOADER:
BOOTLOADER grub

##  HOSTNAME:
HOSTNAME hetzner-arch-luks
#Adapt the hostname to your needs

##  PARTITIONS / FILESYSTEMS:
PART /boot  btrfs     512M
PART lvm    vg0       all
LV vg0   swap   swap     swap         8G
LV vg0   root   /        btrfs        10G

##  OPERATING SYSTEM IMAGE:
IMAGE /root/.oldroot/nfs/install/../images/archlinux-latest-64-minimal.tar.gz
```
#### 1.3 Install Image
:ambulance: :
```bash
installimage
```
#### 1.4 Restart
:ambulance: :
```bash
reboot
```

### 2. Setup System
#### 2.1 Login to server
:computer: :
```bash
ssh-keygen -f "$HOME/.ssh/known_hosts" -R your_server_ip
ssh root@your_server_ip
```
#### 2.2 Update the system
:minidisc: :
```bash
pacman -Syyu
```
#### 2.3 Install administration tools:
:minidisc: :
```bash
pacman -S nano
```

### 3. Prepare System for Unlocking via SSH
#### 3.1 Install software
:minidisc: :
```bash
pacman -S busybox mkinitcpio-dropbear mkinitcpio-utils mkinitcpio-netconf
```
#### 3.2 Copy authorized keys to dropbear
:minidisc: :
```bash
cp -v ~/.ssh/authorized_keys /etc/dropbear/root_key
```

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
systemctl enable sshd
```

#### 3.3 Regenerate OpenSSH keys
:minidisc: :
```bash
rm /etc/ssh/ssh_host_*
ssh-keygen -A -m PEM
```
#### 3.4 Import SSH-keys to dropbear
:minidisc: :
```bash
dropbearconvert openssh dropbear /etc/ssh/ssh_host_rsa_key /etc/dropbear/dropbear_rsa_host_key
```

#### 3.5 Modify /etc/mkinitcpio.conf
:minidisc: :
```bash
nano /etc/mkinitcpio.conf
```
##### Replace
**Old:**
```
HOOKS=(base udev autodetect modconf block mdadm_udev lvm2 filesystems keyboard fsck)
```
**New:**
```
HOOKS=(base udev autodetect modconf block mdadm_udev lvm2 netconf dropbear encryptssh filesystems keyboard fsck)
```

### 4. Activate Encryption
#### 4.1 Activate Rescue System
Activate the rescue system https://robot.your-server.de/server
#### 4.2 Reboot
:minidisc: :
```bash
reboot
```
#### 4.3 Login to the rescue system
:computer: :
```bash
hal connect rescue your_server_ip
```

#### 4.4 Mount the "system"
:ambulance: :
```bash
vgscan -v
vgchange -a y
mount /dev/mapper/vg0-root /mnt
```

#### 4.5 Copy "system"
:ambulance: :
```bash
echo 0 >/proc/sys/dev/raid/speed_limit_max
mkdir /oldroot
cp -va /mnt/. /oldroot/.
echo 200000 >/proc/sys/dev/raid/speed_limit_max
```
#### 4.6 Unmount the "system"
:ambulance: :
```bash
umount /mnt
```

#### 4.7 Delete decrypted LVM-Volume-Group
:ambulance: :
```bash
vgremove vg0
```

#### 4.8 Check drive state
:ambulance: :
```bash
cat /proc/mdstat
```
#### 4.9 Encrypt MD1 by executing
:ambulance: :
```bash
cryptsetup --cipher aes-xts-plain64 --key-size 256 --hash sha256 --iter-time=10000 luksFormat /dev/md1
cryptsetup luksOpen /dev/md1 cryptroot
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
lvcreate -n swap -L8G vg0
lvcreate -n root -L10G vg0
mkfs.btrfs /dev/vg0/root
mkswap /dev/vg0/swap
```

#### 4.10 Mount encrypted
:ambulance: :
```bash
mount /dev/vg0/root /mnt
```

#### 4.12 Copy "system"
:ambulance: :
```bash
echo 0 >/proc/sys/dev/raid/speed_limit_max
cp -av /oldroot/. /mnt/.
echo 200000 >/proc/sys/dev/raid/speed_limit_max
```

#### 4.13 Integrate Finale Installation
:ambulance: :
```bash
mount /dev/md0 /mnt/boot
mount --bind /dev /mnt/dev
mount --bind /sys /mnt/sys
mount --bind /proc /mnt/proc
chroot /mnt
```

#### 4.14
:ghost: :
```bash
echo "cryptroot /dev/md1 none luks" >> /etc/crypttab
```

#### 4.15  Create an initial ramdisk
:ghost: :
```bash
mkinitcpio -p linux
```

### 5 Grub
#### 5.1 Install Grub
:ghost: :
```bash
pacman -S grub
```
#### 5.2 Configure /etc/default/grub

:ghost: :

```bash
nano /etc/default/grub
```

Change the following parameters:
```bash
GRUB_CMDLINE_LINUX="cryptdevice=/dev/md1:cryptroot ip=dhcp"
GRUB_ENABLE_CRYPTODISK=y
```
:information_source: Further [information](https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Configuring_GRUB).
#### 5.3 Make and Install on Hard-drives
:ghost: :
```bash
grub-mkconfig -o /boot/grub/grub.cfg
grub-install /dev/sda
grub-install /dev/sdb
```

#### 5.4 Restart System
:ghost: :ambulance: :
```bash
exit
umount /mnt/boot /mnt/proc /mnt/sys /mnt/dev
umount /mnt
sync
reboot
```
### 6. Encryption Procedure
#### 6.1 Decrypt server
:computer: :
```bash
ssh  -o UserKnownHostsFile=/dev/null root@your_server_ip
cryptroot-unlock
exit
```
#### 6.2 Login to server
:computer: :
```bash
ssh-keygen -f "$HOME/.ssh/known_hosts" -R your_server_ip
ssh root@your_server_ip
```

#### 7. Expand filesystem
:computer: :
```bash
lvresize -l +100%FREE /dev/vg0/root
btrfs filesystem resize max /
```

## 8. Debugging
### 8.1 Login to System from Rescue System
With the rescue system already activated and running, drop straight into the chroot from your client:

:computer: :
```bash
hal connect chroot your_server_ip
```
You'll be prompted for the LUKS passphrase first (hidden input). The CLI then waits for rescue, assembles the RAID, opens LUKS, activates LVM, mounts `/mnt` + `/mnt/boot` + the pseudo-filesystems, and drops you into `chroot /mnt /bin/bash`. Idempotent — re-running while already mounted just re-enters the chroot.

### 8.2 Collect diagnostics in one shot
If you want a non-interactive snapshot of the installed system's state (package versions, last-boot journal errors, sshd status, `/boot` contents, etc.):

:computer: :
```bash
hal diagnose your_server_ip | tee "diagnose-$(date +%F-%H%M).log"
```
The CLI runs the same setup as `connect chroot` and then a fixed inspection script inside the chroot. Output goes to stdout (and the log file via `tee`).

<details>
<summary>Manual equivalent of the unlock + mount sequence</summary>

:ambulance: :
```bash
cryptsetup luksOpen /dev/md1 cryptroot
mount /dev/vg0/root /mnt
mount /dev/md0 /mnt/boot
mount --bind /dev /mnt/dev
mount --bind /sys /mnt/sys
mount --bind /proc /mnt/proc
chroot /mnt
```
</details>
### 8.3 Logout from chroot environment
:ghost: :ambulance: :
```bash
exit
umount /mnt/boot /mnt/proc /mnt/sys /mnt/dev
umount /mnt
sync
reboot
```

### 8.4 Regenerate GRUB and Arch
:ghost: :
```bash
mkinitcpio -p linux
grub-mkconfig -o /boot/grub/grub.cfg
grub-install /dev/sda
grub-install /dev/sdb
```

## Sources
The code is adapted from the following guides:

* http://daemons-point.com/blog/2019/10/20/hetzner-verschluesselt/
* https://www.howtoforge.com/using-the-btrfs-filesystem-with-raid1-with-ubuntu-12.10-on-a-hetzner-server
* https://code.trafficking.agency/arch-linux-remote-unlock-root-volume-with-mdraid-and-dmcrypt.html
* https://wiki.archlinux.org/index.php/Dm-crypt/Specialties#Remote_unlocking_(hooks:_netconf,_dropbear,_tinyssh,_ppp)
* https://gist.github.com/pezz/5310082
