efibootmgr efibootmgr -v -c --label "debian-bullseye (RAID disk $I)" --loader "\EFI\debian\shimx64.efi" --disk /dev/sd${P}2 --part 2
