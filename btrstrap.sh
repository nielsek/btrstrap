#!/bin/sh

suite="bionic"

while getopts "h:d:s:" opt; do
  case "$opt" in
    h) hostname="$OPTARG" ;;
    d) disk="$OPTARG" ;;
    s) suite="$OPTARG" ;;
  esac
done

if [ -z "$hostname" -o -z "$disk" ]; then
    echo "Usage: $0 -h <hostname> -d <disk>"
    echo "Optional:"
    echo "          -s <suite> (trusty)"
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
  echo "Run as root"
  exit 1
fi

arch=""
case "`uname -m`" in
  "x86_64") arch="amd64" ;;
  "i386") arch="i386" ;;
  "i686") arch="i386" ;;
  *) echo "CPU arch unknown" 
     exit 1 ;;
esac
echo "detected $arch"

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
if [ -z "`dpkg -l btrfs-tools`" -o -z "`dpkg -l debootstrap`" -o -z "`dpkg -l curl`" -o -z "`dpkg -l gdisk`" ]; then
  apt-get update
  apt-get install btrfs-tools debootstrap curl gdisk -y
fi

echo "*BTRSTRAP* Wiping $disk"
swapoff -a
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
btrfs subvolume create @
cd ..
umount /dev/${disk}3
mount -o subvol=@ /dev/${disk}3 /mnt/btrroot
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
    btrfs-tools,\
    build-essential,\
    bzip2,\
    ca-certificates,\
    cron,\
    curl,\
    dmidecode,\
    dnsutils,\
    gnupg,\
    ${grubdeb},\
    htop,\
    initramfs-tools,\
    iptables,\
    iputils-ping,\
    less,\
    linux-image-generic,\
    locales,\
    logrotate,\
    lsof,\
    man-db,\
    net-tools,\
    netplan.io,\
    openssh-server,\
    parted,\
    postfix,\
    psmisc,\
    rsync,\
    rsyslog,\
    sysstat,\
    systemd-sysv,\
    tcpdump,\
    sudo,\
    telnet,\
    tzdata,\
    vim,\
" --variant=minbase --arch $arch $suite . $repo

echo "*BTRSTRAP* Creating configs"
echo "$hostname" > etc/hostname

echo "LABEL=btrpool / btrfs subvol=@ 0 0
/dev/${disk}2 /boot ext2 defaults 0 2" > etc/fstab
if [ "$efi" = 1 ]; then
  echo "/dev/${disk}1 /boot/efi vfat defaults 0 1" >> etc/fstab
fi

echo "network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: yes
      dhcp6: no
      nameservers:
        addresses: [1.1.1.1, 1.0.0.1]" > etc/netplan/01-netcfg.yaml

chroot . /bin/bash -c "export LANGUAGE=en_US.UTF-8; export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; locale-gen en_US.UTF-8; dpkg-reconfigure -f noninteractive locales"

echo 'LANG="en_US.UTF-8"
LANGUAGE="en_US:en"' > etc/default/locale

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
