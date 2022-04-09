#!/bin/bash -ex
#
# debian-buster-zfs-root.sh V1.10
#
# Install Debian GNU/Linux 10 Buster to a native ZFS root filesystem
#
# (C) 2018-2019 Hajo Noerenberg
# (C) 2019 Sören Busse
#
# http://www.noerenberg.de/
# https://github.com/hn/debian-buster-zfs-root
#
# https://sbusse.de
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3.0 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.txt>.
#


### Settings from environment
### If you don't want to use environment variables or default values just comment in this variables to modify the values
# RPOOL="rpool"
# TARGETDIST="bullseye"
# SYSTEM_LANGUAGE="en_US.UTF-8"
# SYSTEM_NAME="debian"
# SIZESWAP="2G"
# SIZETMP="3G"
# SIZEVARTMP="3G"
# ENABLE_EXTENDED_ATTRIBUTES="on"
# ENABLE_EXECUTE_TMP="off"
# ENABLE_AUTO_TRIM="on"
# ADDITIONAL_BACKPORTS_PACKAGES=package1,package2,package3,make,sure,to,use,commas
# ADDITIONAL_PACKAGES=package1,package2,package3,make,sure,to,use,commas
# POST_INSTALL_SCRIPT=script.sh

if [ -f "environment.conf" ]; then
    . ./environment.conf
fi

. ./constants.sh
. ./helper-functions.sh
. ./create_datasets.sh
. ./setup-base-system.sh

# Name of boot and main ZFS pools
BPOOL="${BPOOL:-bpool}"
RPOOL="${RPOOL:-rpool}"

# The debian version to install
TARGETDIST="${TARGETDIST:-bullseye}"

# Language
SYSTEM_LANGUAGE="${SYSTEM_LANGUAGE:-en_US.UTF-8}"

# System name. This name will be used as hostname and as dataset name: rpool/ROOT/SystemName
SYSTEM_NAME="${SYSTEM_NAME:-debian-${TARGETDIST}}"

# Sizes for temporary content and swap
SIZESWAP="${SIZESWAP:-2G}"
SIZETMP="${SIZETMP:-3G}"
SIZEVARTMP="${SIZEVARTMP:-3G}"

# The extended attributes will improve performance but reduce compatibility with non-Linux ZFS implementations
# Enabled by default because we're using a Linux compatible ZFS implementation
ENABLE_EXTENDED_ATTRIBUTES="${ENABLE_EXTENDED_ATTRIBUTES:-on}"

# Allow execute in /tmp
# Possible values: off, on
ENABLE_EXECUTE_TMP="${ENABLE_EXECUTE_TMP:-off}"

# Enable autotrim
# Possible values: off, on
ENABLE_AUTO_TRIM="${ENABLE_AUTO_TRIM:-on}"

# Additional packages to install on the final system
if [[ -n $ADDITIONAL_BACKPORTS_PACKAGES ]]; then
	IFS=',' read -r -a ADDITIONAL_BACKPORTS_PACKAGES <<< "${ADDITIONAL_BACKPORTS_PACKAGES}";
else
	ADDITIONAL_BACKPORTS_PACKAGES=()
fi

if [[ -n $ADDITIONAL_PACKAGES ]]; then
	IFS=',' read -r -a ADDITIONAL_PACKAGES <<< "${ADDITIONAL_PACKAGES}";
else
	ADDITIONAL_PACKAGES=()
fi

POST_INSTALL_SCRIPT=${POST_INSTALL_SCRIPT:-""}

### User settings
if [ "$(id -u )" != "0" ]; then
	echo "You need to run this script as root"
	exit 1
fi


SETTINGS_SUMMARY=$(cat <<EOF
The system will be installed with the following options. Is this correct?
ZPool name: $RPOOL
Version: $TARGETDIST
Language: $SYSTEM_LANGUAGE
System name: $SYSTEM_NAME
Swap size: $SIZESWAP
Size /tmp: $SIZETMP
Size /var/tmp: $SIZEVARTMP
Enable extended attributes: $ENABLE_EXTENDED_ATTRIBUTES
Enable execute in /tmp: $ENABLE_EXECUTE_TMP
Enable autotrim: $ENABLE_AUTO_TRIM
Additional backports packages: ${ADDITIONAL_BACKPORTS_PACKAGES[@]}
Additional packages: ${ADDITIONAL_PACKAGES[@]}
Postscript to execute after installation (only if set): $POST_INSTALL_SCRIPT
EOF
)

whiptail --title "Settings summary" --yesno "$SETTINGS_SUMMARY" 20 78

if [[ $? != 0 ]]; then
    exit 1;
fi

declare -A BYID
while read -r IDLINK; do
	BYID["$(basename "$(readlink "$IDLINK")")"]="$IDLINK"
done < <(find /dev/disk/by-id/ -type l)

for DISK in $(lsblk -I8,254,259 -dn -o name); do
        dsize=$(lsblk -dn -o size /dev/$DISK|tr -d " ")
	if [ -z "${BYID[$DISK]}" ]; then
		SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
	else
		SELECT+=("$DISK" "${BYID[$DISK]} ($dsize)" off)
	fi
done

TMPFILE=$(mktemp)
whiptail --backtitle "$0" --title "Drive selection" --separate-output \
	--checklist "\nPlease select ZFS RAID drives\n" 20 74 8 "${SELECT[@]}" 2>"$TMPFILE"

if [ $? -ne 0 ]; then
	exit 1
fi

while read -r DISK; do
	if [ -z "${BYID[$DISK]}" ]; then
		DISKS+=("/dev/$DISK")
		BOOTPARTITIONS+=("/dev/$DISK$PARTBOOT")
		ROOTPARTITIONS+=("/dev/$DISK$PARTROOT")		
		EFIPARTITIONS+=("/dev/$DISK$PARTEFI")
	else
		DISKS+=("${BYID[$DISK]}")
		BOOTPARTITIONS+=("${BYID[$DISK]}-part$PARTBOOT")
		ROOTPARTITIONS+=("${BYID[$DISK]}-part$PARTROOT")		
		EFIPARTITIONS+=("${BYID[$DISK]}-part$PARTEFI")
	fi
done < "$TMPFILE"

whiptail --backtitle "$0" --title "RAID level selection" --separate-output \
	--radiolist "\nPlease select ZFS RAID level\n" 20 74 8 \
	"RAID0" "Striped disks" off \
	"RAID1" "Mirrored disks (RAID10 for n>=4)" on \
	"RAIDZ" "Distributed parity, one parity block" off \
	"RAIDZ2" "Distributed parity, two parity blocks" off \
	"RAIDZ3" "Distributed parity, three parity blocks" off 2>"$TMPFILE"

if [ $? -ne 0 ]; then
	exit 1
fi

RAIDLEVEL=$(head -n1 "$TMPFILE" | tr '[:upper:]' '[:lower:]')

GRUBTYPE=$BIOS
if [ -d /sys/firmware/efi ]; then
	whiptail --backtitle "$0" --title "EFI boot" --separate-output \
		--menu "\nYour hardware supports EFI. Which boot method should be used in the new to be installed system?\n" 20 74 8 \
		"EFI" "Extensible Firmware Interface boot" \
		"BIOS" "Legacy BIOS boot" 2>"$TMPFILE"

	if [ $? -ne 0 ]; then
		exit 1
	fi

	if grep -qi EFI $TMPFILE; then
		GRUBTYPE=$EFI
	fi
fi

whiptail --backtitle "$0" --title "Confirmation" \
	--yesno "\nAre you sure to destroy ZFS pool '$RPOOL' (if existing), wipe all data of disks '${DISKS[*]}' and create a RAID '$RAIDLEVEL'?\n" 20 74

if [ $? -ne 0 ]; then
	exit 1
fi

### Start the real work

# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=595790
if [ "$(hostid | cut -b-6)" == "007f01" ]; then
	dd if=/dev/urandom of=/etc/hostid bs=1 count=4
fi

# Update apt before doing anything
apt-get update

# All needed packages to install ZFS. We let apt do the work to check whether the package is already installed
need_packages=(debootstrap gdisk dosfstools dpkg-dev linux-headers-amd64 linux-image-amd64)

# Required packages for EFI
if [ "$GRUBTYPE" == "$EFI" ]; then need_packages+=(efibootmgr); fi

# Install packages to the live environment
echo "Install packages:" "${need_packages[@]}"
DEBIAN_FRONTEND=noninteractive apt-get install --yes "${need_packages[@]}"

deb_release=$(head -n1 /etc/debian_version)
echo "Install additional packages"
install_packages "$deb_release" false zfs-dkms zfsutils-linux

modprobe zfs
if [ $? -ne 0 ]; then
	echo "Unable to load ZFS kernel module" >&2
	exit 1
fi

test -d /proc/spl/kstat/zfs/$RPOOL && zpool destroy $RPOOL

# for DISK in "${DISKS[@]}"; do
# 	echo -e "\nPartitioning disk $DISK"

# 	sgdisk --zap-all $DISK

# 	# sgdisk -a1 -n$PARTBIOS:34:2047 -t$PARTBIOS:EF02 $DISK
# 	# sgdisk -n$PARTEFI:2048:+512M   -t$PARTEFI:EF00  $DISK
# 	# sgdisk -n$PARTBOOT:0:+2G       -t$PARTBOOT:BF01 $DISK
# 	# sgdisk -n$PARTROOT:0:0         -t$PARTROOT:BF00 $DISK	
# 	sgdisk -a1 -n$PARTBIOS:24k:+1000k -t$PARTBIOS:EF02 $DISK
# 	sgdisk -n$PARTEFI:1M:+512M        -t$PARTEFI:EF00  $DISK
# 	sgdisk -n$PARTBOOT:0:+2G       -t$PARTBOOT:BF01 $DISK
# 	sgdisk -n$PARTROOT:0:0         -t$PARTROOT:BF00 $DISK	
# done

# sleep 2

# creating the boot pool
#PARTITIONS=${BOOTPARTITIONS}
raid_def ${BOOTPARTITIONS[@]}

zpool create -f \
      -o ashift=12 \
      -o cachefile=/etc/zfs/zpool.cache \
      -o autotrim=$ENABLE_AUTO_TRIM \
      -o feature@async_destroy=enabled \
      -o feature@bookmarks=enabled \
      -o feature@embedded_data=enabled \
      -o feature@empty_bpobj=enabled \
      -o feature@enabled_txg=enabled \
      -o feature@extensible_dataset=enabled \
      -o feature@filesystem_limits=enabled \
      -o feature@hole_birth=enabled \
      -o feature@large_blocks=enabled \
      -o feature@livelist=enabled \
      -o feature@lz4_compress=enabled \
      -o feature@spacemap_histogram=enabled \
      -o feature@zpool_checkpoint=enabled \
      -O atime=off -O relatime=on \
      -O normalization=formD \
      -O devices=off \
      -O canmount=off -O mountpoint=/boot -R /target \
      $BPOOL $RAIDDEF
# note to above: could also set property altroot instead of -R

if [ $? -ne 0 ]; then
	echo "Unable to create zpool '$BPOOL'" >&2
	exit 1
fi

# Enable extended attributes on this pool
if [ "$ENABLE_EXTENDED_ATTRIBUTES" == "on" ]; then
	zfs set xattr=sa $BPOOL
	zfs set acltype=posixacl $BPOOL
fi

raid_def "${ROOTPARTITIONS[@]}"
# create the root pool
zpool create \
    -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=zstd \
    -O dnodesize=auto -O normalization=formD -O relatime=on \
    -O xattr=sa -O mountpoint=/ -R /target \
    $RPOOL $RAIDDEF

# create the datasets
create_datasets
create_optional_datasets
setup_base_system
zfs_boot_setup

install_grub

final_settings

if [ -n "$POST_INSTALL_SCRIPT" ] && [ -f "$POST_INSTALL_SCRIPT" ]; then
    target_script="post-script.sh"

    cp "$POST_INSTALL_SCRIPT" "/target/$target_script"
    chmod +x "/target/$target_script"
    chroot /target /$target_script
    rm "/target/$target_script"
fi

sync

#zfs umount -a

## chroot /target /bin/bash --login
## zpool import -R /target rpool

