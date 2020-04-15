# Arch Linux with LUKS and btrfs on a hetzner server
This guide should show you how to set up an System with the following specifications on an hetzner server:
* Arch Linux
* btrfs
* LUKS

## Guide

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

## Sources
The code is adapted from the following guides:

* http://daemons-point.com/blog/2019/10/20/hetzner-verschluesselt/
* https://www.howtoforge.com/using-the-btrfs-filesystem-with-raid1-with-ubuntu-12.10-on-a-hetzner-server
