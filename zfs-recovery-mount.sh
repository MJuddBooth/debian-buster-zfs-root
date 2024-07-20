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

if [ -f "environment.conf" ]; then
    . ./environment.conf
fi

zpool import -N $RPOOL -R /target
zpool import -N $BPOOL -R /target

zfs mount $RPOOL/ROOT/debian
zfs mount -a

mount -t zfs $RPOOL/var     /target/var
mount -t zfs $RPOOL/usr     /target/usr
mount -t zfs $RPOOL/var/tmp /target/var/tmp


mount --rbind /dev /target/dev
mount --rbind /proc /target/proc
mount --rbind /sys /target/sys
ln -sf /proc/mounts /target/etc/mtab

# make the teardown function available
. ./setup-base-system.sh 
