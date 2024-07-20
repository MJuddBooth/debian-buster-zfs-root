#
# create root and boot pools
#

function create_boot_pool() {
    local bpool=$1
    local raiddef=$2
    ENABLE_AUTO_TRIM=on
    zpool create -f \
	  -o ashift=12 \
	  -o cachefile=/etc/zfs/zpool.cache \
	  -o autotrim=$ENABLE_AUTO_TRIM \
	  -o compatibility=grub2 \
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
	  $bpool $raiddef
    # note to above: could also set property altroot instead of -R

    if [ $? -ne 0 ]; then
	echo "Unable to create zpool '$bpool'" >&2
	return
    fi

    # Enable extended attributes on this pool
    if [ "$ENABLE_EXTENDED_ATTRIBUTES" == "on" ]; then
	zfs set xattr=sa $bpool
	zfs set acltype=posixacl $bpool
    fi
}

function create_root_pool() {
    local rpool=$1
    local raiddef=$2
    
    zpool create \
	  -o ashift=12 \
	  -o autotrim=on \
	  -O acltype=posixacl \
	  -O xattr=sa \
	  -O dnodesize=auto \
	  -O compression=zstd \
	  -O normalization=formD \
	  -O relatime=on \
	  -O canmount=off \
	  -O mountpoint=/ -R /target \
	  $rpool $raiddef
}
