#!/bin/sh
# Create the ROMFS while Buildroot's fakeroot metadata is active.

set -eu

target_dir=$1
: "${BINARIES_DIR:?Buildroot did not export BINARIES_DIR}"

romfs_image="$BINARIES_DIR/rootfs.romfs"
romfs_tmp="$romfs_image.tmp"
romfs_max_size=$((0x00060000))

command -v genromfs >/dev/null 2>&1 || {
    echo "genromfs is required to create $romfs_image" >&2
    exit 1
}

# Match Buildroot's filesystem cleanup, which normally happens after the
# post-fakeroot hooks, so the separately generated ROMFS remains reproducible.
find "$target_dir/run" -mindepth 1 -prune -exec rm -rf -- {} +
find "$target_dir/tmp" -mindepth 1 -prune -exec rm -rf -- {} +
if test -n "${SOURCE_DATE_EPOCH:-}"; then
    find "$target_dir" -exec touch -h -d "@$SOURCE_DATE_EPOCH" -- {} +
fi

rm -f -- "$romfs_tmp"
trap 'rm -f -- "$romfs_tmp"' EXIT HUP INT TERM
genromfs -f "$romfs_tmp" -d "$target_dir" -V rootfs

romfs_size=$(wc -c <"$romfs_tmp")
test "$romfs_size" -le "$romfs_max_size" || {
    echo "ROMFS too large: $romfs_size bytes (Flash area: $romfs_max_size bytes)" >&2
    exit 1
}
test "$(dd if="$romfs_tmp" bs=8 count=1 2>/dev/null)" = '-rom1fs-' || {
    echo "invalid ROMFS signature in $romfs_tmp" >&2
    exit 1
}

mv -f -- "$romfs_tmp" "$romfs_image"
trap - EXIT HUP INT TERM
printf 'ROMFS: %s bytes -> %s\n' "$romfs_size" "$romfs_image"
