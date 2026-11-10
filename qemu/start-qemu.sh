#!/usr/bin/env bash
# Installed in output/images; the effective Buildroot config selects the boot path.
set -euo pipefail
images=$(cd -- "$(dirname -- "$0")" && pwd -P)
out=${images%/*}
config="$out/.config"
[[ -s "$config" ]] || { echo "Missing Buildroot config: $config" >&2; exit 1; }
for option in "$@"; do
    [[ "$option" == --serial-only ]] || { echo "Unknown option: $option" >&2; exit 2; }
done

kernel="$images/zImage"
dtb="$images/vexpress-v2p-ca9.dtb"
required=("$kernel" "$dtb" "$out/host/bin/qemu-system-arm")
cmd=("$out/host/bin/qemu-system-arm" -M vexpress-a9 -smp 1 -m 256 -nographic
     -net nic,model=lan9118 -net user)
bootargs='console=ttyAMA0,115200'

if grep -qx 'BR2_TARGET_ROOTFS_INITRAMFS=y' "$config"; then
    echo 'Root filesystem: initramfs embedded in zImage'
else
    required+=("$images/rootfs.ext2")
    cmd+=(-drive "file=$images/rootfs.ext2,if=sd,format=raw")
    bootargs+=' rootwait root=/dev/mmcblk0'
fi

if grep -qx 'BR2_TARGET_UBOOT=y' "$config"; then
    required+=("$images/u-boot.bin")
    # QEMU preloads Linux/DTB into RAM; U-Boot executes bootz (see uboot.fragment).
    cmd+=(-bios "$images/u-boot.bin"
          -device "loader,file=$kernel,addr=0x62000000,force-raw=on"
          -device "loader,file=$dtb,addr=0x63000000,force-raw=on")
    echo 'Boot: U-Boot -> Linux (kernel 0x62000000, DTB 0x63000000)'
else
    cmd+=(-kernel "$kernel" -dtb "$dtb" -append "$bootargs")
    echo 'Boot: direct Linux'
fi
for file in "${required[@]}"; do
    [[ -s "$file" ]] || { echo "Missing or empty file: $file" >&2; exit 1; }
done
if grep -qx 'BR2_TARGET_UBOOT=y' "$config" && (( $(stat -c %s "$kernel") > 0x1000000 )); then
    echo 'zImage overlaps the DTB preload address (0x63000000)' >&2
    exit 1
fi
exec "${cmd[@]}"
