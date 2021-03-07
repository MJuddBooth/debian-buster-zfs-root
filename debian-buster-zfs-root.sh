#!/bin/bash -e
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

## Functions
# Joins an array
# Delimiter
function join() {
    local IFS="$1"
    shift
    echo "$*"
}

# $1: str: Debian release version
# $2: bool: Run in Chroot
# $...: Packages
function install_backports_packages() {
	destination="/etc/apt/sources.list.d/backports.list"

	# Add chroot prefix if set
	if $2; then
		destination="/target${destination}"
	fi

	case $1 in
		9*|stretch*)
			echo "deb http://deb.debian.org/debian stretch-backports main contrib non-free" >"$destination"
			backports_version="stretch-backports"
			;;
		10*|buster*)
			echo "deb http://deb.debian.org/debian buster-backports main contrib non-free" >"$destination"
			backports_version="buster-backports"
			;;
		*)
			echo "Unsupported debian version" >&2
			exit 1
			;;
	esac

	if $2; then
		chroot /target /usr/bin/apt-get update
		chroot /target /usr/bin/apt-get install --yes -t $backports_version "${@:3}"
	else
		apt-get update
		apt-get install --yes -t $backports_version "${@:3}"
	fi
}


### Constants
BIOS="bios"
EFI="efi"

PARTBIOS=1
PARTEFI=2
PARTZFS=3

### Settings from environment
### If you don't want to use environment variables or default values just comment in this variables to modify the values
# ZPOOL="rpool"
# TARGETDIST="buster"
# SYSTEM_LANGUAGE="en_US.UTF-8"
# SYSTEM_NAME="debian-buster"
# SIZESWAP="2G"
# SIZETMP="3G"
# SIZEVARTMP="3G"
# ENABLE_EXTENDED_ATTRIBUTES="on"
# ENABLE_EXECUTE_TMP="off"
# ENABLE_AUTO_TRIM="on"
# ADDITIONAL_BACKPORTS_PACKAGES=package1,package2,package3,make,sure,to,use,commas
# ADDITIONAL_PACKAGES=package1,package2,package3,make,sure,to,use,commas
# POST_INSTALL_SCRIPT=script.sh

# Name of main ZFS pool
ZPOOL="${ZPOOL:-BOOT}"

# The debian version to install
TARGETDIST="${TARGETDIST:-buster}"

# Language
SYSTEM_LANGUAGE="${SYSTEM_LANGUAGE:-en_US.UTF-8}"

# System name. This name will be used as hostname and as dataset name: rpool/ROOT/SystemName
SYSTEM_NAME="${SYSTEM_NAME:-debian-${TARGETDIST}}"

# Sizes for temporary content and swap
# SIZESWAP="${SIZESWAP:-2G}"
# SIZETMP="${SIZETMP:-3G}"
# SIZEVARTMP="${SIZEVARTMP:-3GB}"

# The extended attributes will improve performance but reduce compatibility with non-Linux ZFS implementations
# Enabled by default because we're using a Linux compatible ZFS implementation
ENABLE_EXTENDED_ATTRIBUTES="${ENABLE_EXTENDED_ATTRIBUTES:-on}"

# Allow execute in /tmp
# Possible values: off, on
# ENABLE_EXECUTE_TMP="${ENABLE_EXECUTE_TMP:-off}"

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
ZPool name: $ZPOOL
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
	if [ -z "${BYID[$DISK]}" ]; then
		SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
	else
		SELECT+=("$DISK" "${BYID[$DISK]}" off)
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
		ZFSPARTITIONS+=("/dev/$DISK$PARTZFS")
		EFIPARTITIONS+=("/dev/$DISK$PARTEFI")
	else
		DISKS+=("${BYID[$DISK]}")
		ZFSPARTITIONS+=("${BYID[$DISK]}-part$PARTZFS")
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

case "$RAIDLEVEL" in
	raid0)
	RAIDDEF="${ZFSPARTITIONS[*]}"
		;;
	raid1)
	if [ $((${#ZFSPARTITIONS[@]} % 2)) -ne 0 ]; then
		echo "Need an even number of disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	I=0
	for ZFSPARTITION in "${ZFSPARTITIONS[@]}"; do
		if [ $((I % 2)) -eq 0 ]; then
			RAIDDEF+=" mirror"
		fi
		RAIDDEF+=" $ZFSPARTITION"
		((I++)) || true
	done
		;;
	*)
	if [ ${#ZFSPARTITIONS[@]} -lt 3 ]; then
		echo "Need at least 3 disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	RAIDDEF="$RAIDLEVEL ${ZFSPARTITIONS[*]}"
		;;
esac

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
	--yesno "\nAre you sure to destroy ZFS pool '$ZPOOL' (if existing), wipe all data of disks '${DISKS[*]}' and create a RAID '$RAIDLEVEL'?\n" 20 74

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
echo "Install backports packages"
install_backports_packages "$deb_release" false zfs-dkms zfsutils-linux

modprobe zfs
if [ $? -ne 0 ]; then
	echo "Unable to load ZFS kernel module" >&2
	exit 1
fi

test -d /proc/spl/kstat/zfs/$ZPOOL && zpool destroy $ZPOOL

for DISK in "${DISKS[@]}"; do
	echo -e "\nPartitioning disk $DISK"

	sgdisk --zap-all $DISK

	sgdisk -a1 -n$PARTBIOS:34:2047   -t$PARTBIOS:EF02 \
						 -n$PARTEFI:2048:+512M -t$PARTEFI:EF00 \
									 -n$PARTZFS:0:0        -t$PARTZFS:BF01 $DISK
done

sleep 2

zpool create -f -o ashift=12 -o altroot=/target -d \
-o feature@async_destroy=enabled \
-o feature@bookmarks=enabled \
-o feature@embedded_data=enabled \
-o feature@empty_bpobj=enabled \
-o feature@enabled_txg=enabled \
-o feature@extensible_dataset=enabled \
-o feature@filesystem_limits=enabled \
-o feature@hole_birth=enabled \
-o feature@large_blocks=enabled \
-o feature@lz4_compress=enabled \
-o feature@spacemap_histogram=enabled \
-o feature@userobj_accounting=enabled \
-O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off -O mountpoint=none \
-O normalization=formD -O relatime=on -O xattr=sa \
$ZPOOL $RAIDDEF
if [ $? -ne 0 ]; then
	echo "Unable to create zpool '$ZPOOL'" >&2
	exit 1
fi
zfs set compression=on ${BOOT_POOL}

zfs create $ZPOOL/ROOT
zfs create -o mountpoint=/ $ZPOOL/ROOT
zpool set bootfs=$ZPOOL/ROOT $ZPOOL

zpool status
zfs list

# Create linux system with preinstalled packages
need_packages=(openssh-server locales linux-headers-amd64 linux-image-amd64 \
rsync sharutils psmisc htop patch less man console-setup keyboard-configuration \
"${ADDITIONAL_PACKAGES[@]}")
include=$(join , "${need_packages[@]}")

debootstrap --include="$include" \
 						--components main,contrib,non-free \
 						$TARGETDIST /target http://deb.debian.org/debian/

echo "$SYSTEM_NAME" >/target/etc/hostname
sed -i "1s/^/127.0.1.1\t$SYSTEM_NAME\n/" /target/etc/hosts

# Copy hostid as the target system will otherwise not be able to mount the misleadingly foreign file system
cp -va /etc/hostid /target/etc/

mount --rbind /dev /target/dev
mount --rbind /proc /target/proc
mount --rbind /sys /target/sys
ln -s /proc/mounts /target/etc/mtab

sed -i "s/# \($SYSTEM_LANGUAGE\)/\1/g" /target/etc/locale.gen
echo "LANG=\"$SYSTEM_LANGUAGE\"" > /target/etc/default/locale
chroot /target /usr/sbin/locale-gen

# Get debian version in chroot environment
install_backports_packages "$TARGETDIST" true zfs-initramfs zfs-dkms "${ADDITIONAL_BACKPORTS_PACKAGES[@]}"

# Select correct grub for the requested plattform
if [ "$GRUBTYPE" == "$EFI" ]; then
	GRUBPKG="grub-efi-amd64"
else
	GRUBPKG="grub-pc"
fi

chroot /target /usr/bin/apt-get install --yes grub2-common $GRUBPKG
grep -q zfs /target/etc/default/grub || perl -i -pe 's/quiet/boot=zfs quiet/' /target/etc/default/grub
chroot /target /usr/sbin/update-grub

if [ "$GRUBTYPE" == "$EFI" ]; then
	# "This is arguably a mis-design in the UEFI specification - the ESP is a single point of failure on one disk."
	# https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition

	mkdir -pv /target/boot/efi
	I=0
	for EFIPARTITION in "${EFIPARTITIONS[@]}"; do
		BOOTLOADERID="$SYSTEM_NAME (RAID disk $I)"

		mkdosfs -F 32 -n EFI-$I $EFIPARTITION
		mount $EFIPARTITION /target/boot/efi

		# Install grub to the EFI directory without setting an EFI entry to the NVRAM
		# We need to add the EFI entry manually because the --bootloader-id doesn't work when using secure boot
		# This is because the grubx64.efi has /EFI/debian/grub hardcoreded for secure boot reasons
		# As a workaround we install grub into /EFI/debian/grub and add the EFI entrys per disk manually
		# See: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=%23925309
		chroot /target /usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram --recheck --no-floppy
		umount $EFIPARTITION

		# Delete entry from EFI if it already exists
		while read -r bootnum; do
			efibootmgr -b $bootnum --delete-bootnum
		done < <(efibootmgr | grep "$BOOTLOADERID" | sed "s/^Boot\(....\).*$/\1/g")

		# Add EFI entry for this disk
		efibootmgr -c --label "$BOOTLOADERID" --loader "\EFI\debian\shimx64.efi" --disk "$EFIPARTITION" --part $PARTEFI

		if [ $I -gt 0 ]; then
			EFIBAKPART="#"
		fi
		echo "${EFIBAKPART}PARTUUID=$(blkid -s PARTUUID -o value $EFIPARTITION) /boot/efi vfat defaults 0 1" >> /target/etc/fstab
		((I++)) || true
	done
fi

ETHDEV=$(ip addr show | awk '/inet.*brd/{print $NF; exit}')
test -n "$ETHDEV" || ETHDEV=enp0s1
echo -e "\nauto $ETHDEV\niface $ETHDEV inet dhcp\n" >>/target/etc/network/interfaces
echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" >> /target/etc/resolv.conf

chroot /target /usr/bin/passwd
chroot /target /usr/sbin/dpkg-reconfigure tzdata
chroot /target /usr/sbin/dpkg-reconfigure keyboard-configuration

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
