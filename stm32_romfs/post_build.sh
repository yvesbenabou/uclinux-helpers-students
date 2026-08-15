#!/bin/sh
# Adapt the Buildroot target tree for a read-only ROMFS root.

set -eu

target_dir=$1
inittab="$target_dir/etc/inittab"
fstab="$target_dir/etc/fstab"
fstab_tmp="$fstab.romfs.$$"

test -f "$inittab"
test -f "$fstab"

# A ROMFS root cannot be remounted read-write.
sed -i '\|^::sysinit:/bin/mount -o remount,rw /$|d' "$inittab"

# Keep transient state writable without CONFIG_TMPFS, which is unavailable on
# this no-MMU kernel. Buildroot's /var/{cache,log,spool,tmp,run,lock} links then
# resolve into these ramfs mounts.
awk '
    $2 == "/" {
        $1 = "mtd0"; $3 = "romfs"; $4 = "ro,noauto"; $5 = 0; $6 = 0
    }
    $2 == "/dev/shm" || $2 == "/tmp" || $2 == "/run" {
        $1 = "ramfs"; $3 = "ramfs"
    }
    { print }
' OFS='\t' "$fstab" >"$fstab_tmp"
mv -f "$fstab_tmp" "$fstab"

# seedrng persists a seed below /var/lib; that location is intentionally
# read-only in this small ROMFS setup.
rm -f "$target_dir/etc/init.d/S01seedrng"

grep -q '^mtd0[[:space:]]\+/[[:space:]]\+romfs[[:space:]]\+ro,noauto' "$fstab"
test "$(grep -c '[[:space:]]ramfs[[:space:]]' "$fstab")" -eq 3
! grep -q 'remount,rw /' "$inittab"
