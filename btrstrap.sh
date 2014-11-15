#!/bin/sh

arch="amd64"
suite="trusty"

while getopts "h:d:" opt; do
    case "$opt" in
        h) hostname="$OPTARG" ;;
        d) disk="$OPTARG" ;;
    esac
done

if [ -z "$disk" ]; then
    echo "Usage: $0 -h <hostname> -d <disk>"
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
  echo "Run as root"
  exit 1
fi

test -e /sys/firmware/efi && efi=1 || efi=0
if [ "$efi" = 1 ]; then
  echo "detected EFI"
  grubdeb="grub-efi"
else
  echo "detected BIOS"
  grubdeb="grub-pc"
fi

echo "Attempting to btrstrap ${suite}/${arch} on /dev/$disk - CTRL+C now to exit"
read horse

echo "*BTRSTRAP* Resolving dependencies"
if [ -z "`dpkg -l btrfs-tools`" -o -z "`dpkg -l debootstrap`" -o -z "`dpkg -l curl`" ]; then
  apt-get update
  apt-get install btrfs-tools debootstrap curl -y
fi

echo "*BTRSTRAP* Wiping $disk"
sgdisk -Z /dev/${disk}
dd if=/dev/zero of=/dev/${disk} bs=1K count=2M

echo "*BTRSTRAP* Creating new layout"
parted /dev/${disk} mktable gpt
if [ "$efi" = 1 ]; then
  parted -a optimal /dev/${disk} mkpart primary 0% 501759kB i
  parted -a optimal /dev/${disk} mkpart primary 501760kB 1003519kB i
  parted -a optimal /dev/${disk} mkpart primary 1003520kB 100% i
  parted /dev/${disk} set 1 boot on
else
  parted -a optimal /dev/${disk} mkpart primary 0% 1007kB i
  parted -a optimal /dev/${disk} mkpart primary 2048kB 501759kB i
  parted -a optimal /dev/${disk} mkpart primary 501760kB 100% i
  parted /dev/${disk} set 1 bios_grub on
  parted /dev/${disk} set 2 boot on
fi

echo "*BTRSTRAP* Formatting"
if [ "$efi" = 1 ]; then
  mkfs.vfat /dev/${disk}1
fi
mkfs.ext2 /dev/${disk}2
mkfs.btrfs -L btrpool /dev/${disk}3

echo "*BTRSTRAP* Creating root subvolume and boot"
mkdir /mnt/btrroot
mount /dev/${disk}3 /mnt/btrroot
cd /mnt/btrroot
btrfs subvolume create ${suite}-root
cd ..
umount /dev/${disk}3
mount -o subvol=${suite}-root /dev/${disk}3 /mnt/btrroot
mkdir /mnt/btrroot/boot
mount /dev/${disk}2 /mnt/btrroot/boot
if [ "$efi" = 1 ]; then
  mkdir /mnt/btrroot/boot/efi
  mount /dev/${disk}1 /mnt/btrroot/boot/efi
fi
cd /mnt/btrroot

echo "*BTRSTRAP* Debootstrapping the OS"
repolist=`curl -s http://mirrors.ubuntu.com/mirrors.txt 2>/dev/null || echo "http://archive.ubuntu.com/ubuntu/"`
repo=`echo "$repolist" | head -n1`

debootstrap --include="\
    bash-completion,\
    bind9-host,\
    btrfs-tools,\
    build-essential,\
    bzip2,\
    cron,\
    curl,\
    isc-dhcp-client,\
    ${grubdeb},\
    iptables,\
    iputils-ping,\
    less,\
    linux-image-generic,\
    logrotate,\
    lsof,\
    man-db,\
    net-tools,\
    ntp,\
    openssh-server,\
    parted,\
    postfix,\
    rsync,\
    rsyslog,\
    sudo,\
    telnet,\
    vim,\
" --variant=minbase --arch $arch $suite . $repo

echo "*BTRSTRAP* Creating configs"
echo "$hostname" > etc/hostname

echo "LABEL=btrpool / btrfs subvol=${suite}-root 0 0
/dev/sda2 /boot ext2 defaults 0 2" > etc/fstab
if [ "$efi" = 1 ]; then
  echo "/dev/sda1 /boot/efi vfat defaults 0 1" >> etc/fstab
fi

echo "auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp" > etc/network/interfaces

echo "nameserver 8.8.8.8
nameserver 8.8.4.4" > etc/resolv.conf

chroot . /bin/bash -c "export LANGUAGE=en_US.UTF-8; export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; locale-gen en_US.UTF-8; dpkg-reconfigure locales"

echo 'LANG="en_US.UTF-8"
LANGUAGE="en_US:en"' > etc/default/locale

echo "Etc/UTC" > etc/timezone
chroot . dpkg-reconfigure -f noninteractive tzdata

echo 'APT::Install-Recommends "0";
APT::Install-Suggests "0";' > etc/apt/apt.conf.d/99no-install-recommends

echo "deb mirror://mirrors.ubuntu.com/mirrors.txt $suite main
deb mirror://mirrors.ubuntu.com/mirrors.txt $suite-updates main
deb mirror://mirrors.ubuntu.com/mirrors.txt $suite-security main" > etc/apt/sources.list

echo "*BTRSTRAP* Setting up grub"
sed -i"" "s/quiet splash//g" etc/default/grub

mount -o bind /proc ./proc
mount -o bind /dev ./dev
mount -o bind /sys ./sys

if [ "$efi" = 1 ]; then
  chroot . grub-install --target=x86_64-efi --bootloader-id=btrstrap_grub --efi-directory=/boot/efi --recheck --debug
else
  chroot . grub-install --target=i386-pc --boot-directory=/boot --recheck --debug /dev/${disk}
fi

chroot . grub-mkconfig -o /boot/grub/grub.cfg

umount ./proc
umount ./dev
umount ./sys

echo "Enter a password for root:"
chroot . passwd

echo "Wanna enter the new OS, before it gets unmounted? [Y/n]"
read choice

if [ "$choice" != "n" ] && [ "$choice" != "N" ]; then
  chroot .
fi

echo "*BTRSTRAP* Syncing and unmounting disk"
cd ..
sync
if [ "$efi" = 1 ]; then
  umount /dev/${disk}1
fi
umount /dev/${disk}2
umount /dev/${disk}3

echo "All done"
