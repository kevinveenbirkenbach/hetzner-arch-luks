# Arch Linux with LUKS and btrfs on a hetzner server
This guide should show you how to set up an System with the following specifications on an hetzner server:
* Arch Linux
* btrfs
* LUKS

## Guide
### 1. Configure and Install Image
#### 1.1
Login to Hetzner Rescue System
```bash
ssh root@your_server_ip
```
#### 1.2
Create the autosetup by executing

```bash
nano /autosetup
```

and saving the following content into this file:

```bash
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
#### 1.3
Afterwards install the image by executing the following command:

```bash
installimage
```
#### 1.4
When the setup finished restart the server via
```bash
reboot
```

### 2. Setup System
#### 2.1
Revoke old SSH key:
```bash
ssh-keygen -f "$HOME/.ssh/known_hosts" -R your_server_ip
```
#### 2.2
Login to your server:
```bash
ssh root@your_server_ip
```

#### 2.3
Update the system:
```bash
pacman -Syyu
```
#### 2.4
Install basic administration software:
```bash
pacman -Syyu nano
```

#### 3. Prepare System for Unlocking via SSH
#### 3.1 Execute the following script
```bash
# Install software
pacman -Syyu busybox mkinitcpio-dropbear mkinitcpio-utils
#Copy ssh-key
cp ~/.ssh/authorized_keys /etc/dropbear/root_key
```



## Sources
The code is adapted from the following guides:

* http://daemons-point.com/blog/2019/10/20/hetzner-verschluesselt/
* https://www.howtoforge.com/using-the-btrfs-filesystem-with-raid1-with-ubuntu-12.10-on-a-hetzner-server
