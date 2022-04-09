#
#
#
. ./helper-functions.sh

if [ -f "environment.conf" ]; then
	. ./environment.conf
fi

install_packages "$TARGETDIST" false zfs-initramfs zfs-dkms "${ADDITIONAL_BACKPORTS_PACKAGES[@]}"


