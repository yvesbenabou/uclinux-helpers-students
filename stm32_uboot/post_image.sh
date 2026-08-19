#!/usr/bin/env bash
# Wrap Linux's raw XIP image for U-Boot without copying it to RAM.

set -Eeuo pipefail

xip_image="$BINARIES_DIR/xipImage"
uimage="$BINARIES_DIR/uImage"
mkimages=("$BUILD_DIR"/uboot-*/tools/mkimage)

[[ -s "$xip_image" ]] || {
	printf 'missing XIP kernel: %s\n' "$xip_image" >&2
	exit 1
}
[[ "${#mkimages[@]}" -eq 1 && -x "${mkimages[0]}" ]] || {
	printf 'expected exactly one Buildroot U-Boot mkimage under %s\n' "$BUILD_DIR" >&2
	exit 1
}

"${mkimages[0]}" \
	-A arm -O linux -T kernel -C none \
	-a 0x08040040 -e 0x08040040 \
	-n 'STM32F429 XIP Linux' \
	-d "$xip_image" "$uimage"

printf 'U-Boot legacy XIP image: %s bytes -> %s\n' "$(stat -c %s "$uimage")" "$uimage"
