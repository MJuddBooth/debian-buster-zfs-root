# Functions we use
#
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
function install_packages() {
	destination="/etc/apt/sources.list.d/non-free.list"

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
		11*|bullseye*)
			echo "deb http://deb.debian.org/debian bullseye main contrib non-free" >"$destination"
			backports_version="bullseye"
			;;
		12*|bookworm*)
			echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" >"$destination"
			backports_version="bookworm"
			;;
		11*|sid*)
			echo "deb http://deb.debian.org/debian sid main contrib non-free" >"$destination"
			backports_version="sid"
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

function check_modules() {
        modprobe zfs
        if [ $? -ne 0 ]; then
		echo "Unable to load ZFS kernel module" >&2
		exit 1
	fi
}



function raid_def() {
    unset RAIDDEF
    PARTITIONS=("$@")
    echo "PARTITIONS=${PARTITIONS}"
   
    case "$RAIDLEVEL" in
	raid0)
	    RAIDDEF="${PARTITIONS[*]}"
	    ;;
	raid1)
	    if [ $((${#PARTITIONS[@]} % 2)) -ne 0 ]; then
		echo "Need an even number of disks for RAID level '$RAIDLEVEL': ${PARTITIONS[@]}" >&2
		exit 1
	    fi
	    I=0
	    for ZFSPARTITION in "${PARTITIONS[@]}"; do
		if [ $((I % 2)) -eq 0 ]; then
		    RAIDDEF+=" mirror"
		fi
		RAIDDEF+=" $ZFSPARTITION"
		((I++)) || true
	    done
	    ;;
	*)
	    if [ ${#PARTITIONS[@]} -lt 3 ]; then
		echo "Need at least 3 disks for RAID level '$RAIDLEVEL': ${PARTITIONS[@]}" >&2
		exit 1
	    fi
	    RAIDDEF="$RAIDLEVEL ${PARTITIONS[*]}"
	    ;;
    esac
    export RAIDDEF
}
