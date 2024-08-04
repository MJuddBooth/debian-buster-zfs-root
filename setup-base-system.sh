. ./helper-functions.sh

function setup_chroot() {
    mount --rbind /proc /target/proc
    mount --rbind /sys /target/sys
    ln -sf /proc/mounts /target/etc/mtab
    # important: don't link dev, it seems to cause deboostrap to
    # fail with "unable to symlink "/target/dev/fd/fd/"
    #
    if [ -n "${1}" ]; then
	mount --rbind /dev /target/dev
    fi
}

function teardown_chroot() {
    umount /target/dev
    umount -R /target/proc
    umount -R /target/sys
    rm -f /target/etc/mtab
}

function setup_base_system() {
    mkdir -p /target/etc/apt/sources.list.d
    mkdir -p /target/dev
    mkdir -p /target/proc
    mkdir -p /target/sys
    mkdir -p /target/etc/default

    if [[ ${TARGETDIST} == "bookworm" ]]; then
	cp bookworm.list /target/etc/apt/sources.list.d/
    else
	cp bullseye.list /target/etc/apt/sources.list.d/${TARGETDIST}.list
	sed -i "s/bullseye/$TARGETDIST/g"  /target/etc/apt/sources.list.d/${TARGETDIST}.list
    fi
    
    setup_chroot

    # Create linux system with preinstalled packages
    need_packages=(openssh-server linux-headers-amd64 linux-image-amd64 rsync sharutils psmisc htop patch less console-setup keyboard-configuration bash-completion zstd "${ADDITIONAL_PACKAGES[@]}")
    include=$(join , "${need_packages[@]}")

    debootstrap --include="$include" \
 		--components main,contrib,non-free,non-free-firmware \
 		$TARGETDIST /target http://deb.debian.org/debian/

    chroot /target /usr/bin/apt-get install --yes locales
    # cp -p /etc/locale.gen /target/etc/locale.gen    
    sed -i "s/# \($SYSTEM_LANGUAGE\)/\1/g" /target/etc/locale.gen
    echo "LANG=\"$SYSTEM_LANGUAGE\"" > /target/etc/default/locale
    chroot /target /usr/sbin/locale-gen
    
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
#$RPOOL/var/lib		  /var/lib	  zfs 	  defaults	  0	  0
EOF

    # do this again as some of it seems to be undone when deboostrap exists
    
    setup_chroot true
    # Get debian version in chroot environment
    install_packages "$TARGETDIST" true zfs-initramfs zfs-dkms "${ADDITIONAL_BACKPORTS_PACKAGES[@]}"

    if [ -d /proc/acpi ]; then
	chroot /target /usr/bin/apt-get install --yes acpi acpid
	chroot /target service acpid stop
    fi

    ETHDEV=$(ip addr show | awk '/inet.*brd/{print $NF; exit}')
    test -n "$ETHDEV" || ETHDEV=enp0s1
    echo -e "\nauto $ETHDEV\niface $ETHDEV inet dhcp\n" >>/target/etc/network/interfaces
    echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" >> /target/etc/resolv.conf

}

function install_tricky_packages() {
    install_packages "$TARGETDIST" true "${POST_INSTALL_PACKAGES[@]}"
}

function zfs_boot_setup() {
    #mkdir /target/etc/zfs
    
    # force cachefile refresh
    zpool set cachefile=/etc/zfs/zpool.cache $BPOOL
    zpool set cachefile=/etc/zfs/zpool.cache $RPOOL    
    cp /etc/zfs/zpool.cache /target/etc/zfs/

    cp zfs-import-bpool.service /target/etc/systemd/system/
    
    chroot /target systemctl enable zfs-import-bpool.service
    echo RESUME=none > /target/etc/initramfs-tools/conf.d/resume

    mkdir -p /etc/zfs/zfs-list.cache
    touch /etc/zfs/zfs-list.cache/$BPOOL
    touch /etc/zfs/zfs-list.cache/$BPOOL
    zed -F &
    sleep 5
    cp -rp /etc/zfs/zfs-list.cache /target/etc/zfs/
}

function unmount_chroot() {
    mount | grep -v zfs | tac | awk '/\/target/ {print $3}' | \
	xargs -i{} umount -lf {}
    zpool export -a
}

function final_settings() {
    
    chroot /target /usr/bin/passwd
    chroot /target /usr/sbin/dpkg-reconfigure tzdata
    chroot /target /usr/sbin/dpkg-reconfigure keyboard-configuration
}



function setup_base_system_old() {
    
    debootstrap bullseye /target

    mkdir /target/etc/zfs
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    
    cp bullseye.list /target/etc/apt/sources.list

    hostname $HOSTNAME
    hostname > /target/etc/hostname
    
    iface=$(ip -br -o addr show |grep -v lo |awk '{print $1}')
    
    # Bind the virtual filesystems from the LiveCD environment to the new system and chroot into it:

    mount --make-private --rbind /dev  /target/dev
    mount --make-private --rbind /proc /target/proc
    mount --make-private --rbind /sys  /target/sys
    chroot /target /usr/bin/env DISK=$DISK bash --login

    # everything below is supposed to be executed in the chroot
    ln -s /proc/self/mounts /etc/mtab
    apt update
    apt install --yes console-setup locales
    
    apt install --yes dpkg-dev linux-headers-amd64 linux-image-amd64

    apt install --yes zfs-initramfs

    echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf

    apt install dosfstools

    mkdosfs -F 32 -s 1 -n EFI ${DISK}-part2
    mkdir /boot/efi
    echo /dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK}-${PARTEFI}) \
	 /boot/efi vfat defaults 0 0 >> /etc/fstab
    mount /boot/efi
    apt install --yes grub-efi-amd64 shim-signed

    cp zfs-import-bpool.server /etc/systemd/system/
    
    apt install --yes openssh-server
    apt install --yes popularity-contest

    grub-probe /boot
    update-initramfs -c -k all
}
