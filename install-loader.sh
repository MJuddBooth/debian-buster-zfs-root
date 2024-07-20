#!/bin/bash -e -x
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

. ./helper-functions.sh
. ./constants.sh


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

if [ -f "environment.conf" ]; then
	. ./environment.conf
fi

### User settings
if [ "$(id -u )" != "0" ]; then
	echo "You need to run this script as root"
	exit 1
fi

function get_disk_selection() {
    unset SELECT
    unset EFIPARTITIONS
    declare -A BYID
    while read -r IDLINK; do
	BYID["$(basename "$(readlink "$IDLINK")")"]="$IDLINK"
    done < <(find /dev/disk/by-id/ -name "ata*" -type l)

    for DISK in $(lsblk -I8,254,259 -dn -o name); do
        dsize=$(lsblk -dn -o size /dev/$DISK|tr -d " ")
	if [ -z "${BYID[$DISK]}" ]; then
	    SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
	else
	    SELECT+=("$DISK" "${BYID[$DISK]} ($dsize)" off)
	fi
    done

    # echo "SELECT=${SELECT[@]}"    
    TMPFILE=$(mktemp)
    whiptail --backtitle "$0" --title "Drive selection" --separate-output \
	     --checklist "\nPlease select ZFS RAID drives\n" 20 74 8 "${SELECT[@]}" 2>"$TMPFILE"

    if [ $? -ne 0 ]; then
	return 1
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
}

function install_grub() {
    
    if [[ -z $EFIPARTIONS ]]; then
	get_disk_selection
    fi

    # echo "EFI partitions=${EFIPARTITONS[@]}"
    local TMPFILE=$(mktemp)
    GRUBTYPE=$BIOS
    if [ -d /sys/firmware/efi ]; then
	whiptail --backtitle "$0" --title "EFI boot" --separate-output \
		 --menu "\nYour hardware supports EFI. Which boot method should be used in the new to be installed system?\n" 20 74 8 \
		 "EFI" "Extensible Firmware Interface boot" \
		 "BIOS" "Legacy BIOS boot" 2>"$TMPFILE"

	if [ $? -ne 0 ]; then
	    return 1
	fi

	if grep -qi EFI $TMPFILE; then
	    GRUBTYPE=$EFI
	fi
    fi

    # Select correct grub for the requested plattform
    if [ "$GRUBTYPE" == "$EFI" ]; then
	GRUBPKG="grub-efi-amd64"
    else
	GRUBPKG="grub-pc"
    fi

    # make sure we have the needed packages
    chroot /target /usr/bin/apt-get install --yes grub2-common $GRUBPKG
    grep -q zfs /target/etc/default/grub || perl -i -pe 's/quiet/boot=zfs/' /target/etc/default/grub
    sed -i "s|^GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"root=ZFS=$RPOOL/ROOT/debian\"|" /target/etc/default/grub
    chroot /target /usr/sbin/update-grub

    if [ "$GRUBTYPE" == "$EFI" ]; then
	# "This is arguably a mis-design in the UEFI specification - the ESP is a single point of failure on one disk."
	# https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition

	mkdir -pv /target/boot/efi
	I=0
	for EFIPARTITION in "${EFIPARTITIONS[@]}"; do
	    BOOTLOADERID="$SYSTEM_NAME (RAID disk $I)"

	    mkdosfs -F 32 -n EFI-$I $EFIPARTITION
	    echo mount $EFIPARTITION /target/boot/efi	    
	    mount $EFIPARTITION /target/boot/efi

	    # Install grub to the EFI directory without setting an EFI entry to the NVRAM
	    # We need to add the EFI entry manually because the --bootloader-id doesn't work when using secure boot
	    # This is because the grubx64.efi has /EFI/debian/grub hardcoreded for secure boot reasons
	    # As a workaround we install grub into /EFI/debian/grub and add the EFI entrys per disk manually
	    # See: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=%23925309
	    #	    chroot /target /usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram --recheck --no-floppy
	    chroot /target /usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$BOOTLOADERID" --recheck --no-floppy "${DISABLE_SECURE_BOOT}" "${EFIPARTITION}"	    
	    umount $EFIPARTITION

	    # this should not be needed
	    # Delete entry from EFI if it already exists
#	    while read -r bootnum; do
#		efibootmgr -b $bootnum --delete-bootnum
#	    done < <(efibootmgr | grep "$BOOTLOADERID" | sed "s/^Boot\(....\).*$/\1/g")

	    # Add EFI entry for this disk
#	    efibootmgr -c --label "$BOOTLOADERID" --loader "\EFI\debian\shimx64.efi" --disk "$EFIPARTITION" --part $PARTEFI

	    if [ $I -gt 0 ]; then
		EFIBAKPART="#"
	    fi
	    echo "${EFIBAKPART}PARTUUID=$(blkid -s PARTUUID -o value $EFIPARTITION) /boot/efi vfat defaults 0 1" >> /target/etc/fstab
	    ((I++)) || true
	done
    fi

    chroot /target /usr/sbin/update-grub

}


