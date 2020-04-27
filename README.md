# Arch Linux with LUKS and btrfs on a Hetzner server (DRAFT)

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

## Guide
### 1. Configure and Install Image
#### 1.1 Login to Hetzner Rescue System
:computer: :
```bash
ssh root@your_server_ip
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
> :warning: I don't know if the following step is correct. Later during executing ***mkinitcpio -p linux*** the following error appears:
```bash
-> Running build hook: [dropbear]
Error: Unrecognised key type
Error reading key from '/etc/ssh/ssh_host_rsa_key'
Error: Unrecognised key type
Error reading key from '/etc/ssh/ssh_host_dsa_key'
Error: Unrecognised key type
Error reading key from '/etc/ssh/ssh_host_ecdsa_key'
```
I assume this is connected to this.
The following links may help to solve the problem:
* https://github.com/grazzolini/mkinitcpio-dropbear/issues/8
* https://www.reddit.com/r/archlinux/comments/a8pcff/remote_unlock_encrypted_archlinux_with/

```bash
cp -v ~/.ssh/authorized_keys /etc/dropbear/root_key
```

#### 3.3 Modify /etc/mkinitcpio.conf
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
> :warning: In [one of the guides](http://daemons-point.com/blog/2019/10/20/hetzner-verschluesselt/#etcinitramfs-toolsinitramfsconf-anpassen) the ***/etc/initramfs-tools/initramfs.conf*** get modified. Don't know how to implement this for ***mkinitcpio***.<br>
**Old:**
```
BUSYBOX=auto
```
**New:**
```
BUSYBOX=y
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
ssh-keygen -f "$HOME/.ssh/known_hosts" -R your_server_ip
ssh root@your_server_ip
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
> :warning:  I'm not shure if the following is correct. Please check out this [link](https://wiki.archlinux.org/index.php/Dm-crypt/Specialties#Remote_unlocking_(hooks:_netconf,_dropbear,_tinyssh,_ppp)) . I appreciate feedback :two_hearts:

> :warning: I don't know if the raid also needs to be configured in the GRUB_CMDLINE_LINUX parameter.

Change the following parameters:
```bash
GRUB_CMDLINE_LINUX="cryptdevice=/dev/md1:root ip=dhcp"
GRUB_ENABLE_CRYPTODISK=y  # Not secure if necessary
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
## 7. Debugging
### 7.1 Login to System from Rescue System
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
### 7.2 Logout from chroot environment
:ghost: :ambulance: :
```bash
exit
umount /mnt/boot /mnt/proc /mnt/sys /mnt/dev
umount /mnt
sync
reboot
```

### 7.3 Regenerate GRUB and Arch
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
