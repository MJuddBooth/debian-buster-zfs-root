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

# Name of main ZFS pool
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


# Create linux system with preinstalled packages
need_packages=(openssh-server locales linux-headers-amd64 linux-image-amd64 rsync sharutils psmisc htop patch less console-setup keyboard-configuration "${ADDITIONAL_PACKAGES[@]}")
include=$(join , "${need_packages[@]}")

#debootstrap --include="$include" \
# 						--components main,contrib,non-free \
# 						$TARGETDIST /target http://deb.debian.org/debian/

echo "$SYSTEM_NAME" >/target/etc/hostname
sed -i "1s/^/127.0.1.1\t$SYSTEM_NAME\n/" /target/etc/hosts

# Copy hostid as the target system will otherwise not be able to mount the misleadingly foreign file system
cp -va /etc/hostid /target/etc/

cat << EOF >/target/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system>         <mount point>   <type>  <options>       <dump>  <pass>
/dev/zvol/$RPOOL/swap     none            swap    defaults        0       0
$RPOOL/usr                /usr            zfs     defaults        0       0
$RPOOL/var                /var            zfs     defaults        0       0
$RPOOL/var/tmp            /var/tmp        zfs     defaults        0       0
EOF

mount --rbind /dev /target/dev
mount --rbind /proc /target/proc
mount --rbind /sys /target/sys
ln -s /proc/mounts /target/etc/mtab

sed -i "s/# \($SYSTEM_LANGUAGE\)/\1/g" /target/etc/locale.gen
echo "LANG=\"$SYSTEM_LANGUAGE\"" > /target/etc/default/locale
chroot /target /usr/sbin/locale-gen

# Get debian version in chroot environment
install_packages "$TARGETDIST" true zfs-initramfs zfs-dkms "${ADDITIONAL_BACKPORTS_PACKAGES[@]}"

# install grub

if [ -d /proc/acpi ]; then
	chroot /target /usr/bin/apt-get install --yes acpi acpid
	chroot /target service acpid stop
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

