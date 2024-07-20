#!/bin/bash
# this can be run-stand-alone 

if [ -f "environment.conf" ]; then
    . ./environment.conf
fi

# set up the boot pool container

function create_datasets() {
    # boot container and dataset
    zfs create -o canmount=off -o mountpoint=none $BPOOL/BOOT 
    zfs create -o mountpoint=/boot $BPOOL/BOOT/$SYSTEM_NAME
    zpool set bootfs=$BPOOL/BOOT/$SYSTEM_NAME $BPOOL

    # and the root container
    zfs create -o canmount=off -o mountpoint=none $RPOOL/ROOT
    # zfs create -o mountpoint=/ $RPOOL/BOOT/$SYSTEM_NAME
    zfs create -o canmount=noauto -o mountpoint=/ $RPOOL/ROOT/$SYSTEM_NAME 
    zfs mount $RPOOL/ROOT/$SYSTEM_NAME
    
    zfs create -o mountpoint=/tmp -o setuid=off -o exec=$ENABLE_EXECUTE_TMP -o devices=off -o com.sun:auto-snapshot=false -o quota=$SIZETMP $RPOOL/tmp
    chmod 1777 /target/tmp

     # /var needs to be mounted via fstab, the ZFS mount script runs too late during boot
    zfs create -o mountpoint=legacy $RPOOL/var
    mkdir -v /target/var
    mount -t zfs $RPOOL/var /target/var

#    zfs create -o mountpoint=legacy $RPOOL/var/lib
#    mkdir -v /target/var
#    mount -t zfs $RPOOL/var/lib /target/var/lib

    # /usr needs to be mounted via fstab, the ZFS mount script runs too late during boot
    zfs create -o mountpoint=legacy $RPOOL/usr
    mkdir -v /target/usr
    mount -t zfs $RPOOL/usr /target/usr

    # /var/tmp needs to be mounted via fstab, the ZFS mount script runs too late during boot
    zfs create -o mountpoint=legacy -o com.sun:auto-snapshot=false -o quota=$SIZEVARTMP $RPOOL/var/tmp
    mkdir -v -m 1777 /target/var/tmp
    mount -t zfs $RPOOL/var/tmp /target/var/tmp
    chmod 1777 /target/var/tmp

    zfs create $RPOOL/home
    zfs create -o mountpoint=/root $RPOOL/home/root
    
    if [[ $SIZESWAP != "0G" ]]; then
	zfs create -V "$SIZESWAP" -b "$(getconf PAGESIZE)" -o primarycache=metadata -o com.sun:auto-snapshot=false -o logbias=throughput -o sync=always $RPOOL/swap
	# sometimes needed to wait for /dev/zvol/$RPOOL/swap to appear
	sleep 2
	mkswap -f /dev/zvol/$RPOOL/swap
    fi

}

function create_optional_datasets() {

    # Optional datasets
    zfs create -o com.sun:auto-snapshot=false $RPOOL/var/cache
    zfs create                                 $RPOOL/usr/local
    zfs create                                 $RPOOL/var/mail
#    zfs create                                 $RPOOL/var/lib/AccountsService
#    zfs create -o com.sun:auto-snapshot=false  $RPOOL/var/lib/docker
    
    zfs list
    
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "being executed"
    create_datasets
fi

