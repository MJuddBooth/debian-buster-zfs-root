#! /bin/bash

if [ -f "environment.conf" ]; then
    . ./environment.conf
fi

function partition_disks() {
    DISKS=("$@")
    echo "DISKS=${DISKS}"

    for DISK in "${DISKS[@]}"; do
	echo -e "\nPartitioning disk $DISK"
	
	sgdisk --zap-all $DISK

	# sgdisk -a1 -n$PARTBIOS:34:2047 -t$PARTBIOS:EF02 $DISK
	# sgdisk -n$PARTEFI:2048:+512M   -t$PARTEFI:EF00  $DISK
	# sgdisk -n$PARTBOOT:0:+2G       -t$PARTBOOT:BF01 $DISK
	# sgdisk -n$PARTROOT:0:0         -t$PARTROOT:BF00 $DISK	
	# sgdisk -a1 -n$PARTBIOS:24k:+1000k -t$PARTBIOS:EF02 $DISK

	# not sure this works
	# sgdisk -a8 -n$PARTBIOS:34:2047k -t$PARTBIOS:EF02 $DISK	
	# sgdisk -a8 -n$PARTEFI:2M:+512M        -t$PARTEFI:EF00  $DISK
	sgdisk -a1 -n$PARTBIOS:24K:+1000K -t$PARTBIOS:EF02 $DISK	
	sgdisk     -n$PARTEFI:1M:+512M     -t$PARTEFI:EF00  $DISK
	sgdisk -a8 -n$PARTBOOT:0:+2G       -t$PARTBOOT:BF01 $DISK
	sgdisk -a8 -n$PARTROOT:0:0         -t$PARTROOT:BF00 $DISK	
    done
}
