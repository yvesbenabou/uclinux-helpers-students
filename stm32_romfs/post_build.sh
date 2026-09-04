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
rm -f "$target_dir/etc/services" "$target_dir/etc/protocols"
rm -f "$target_dir/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM"

# BusyBox does not remove links belonging to applets disabled after an earlier
# incremental build. Remove only links that still point at its binary.
for applet in \
    cksum crc32 sha1sum sha256sum sha512sum sha3sum \
    mke2fs mkdosfs getfattr lsscsi partprobe setfattr \
    nl ascii factor fallocate hostid svc svok w uudecode uuencode \
    linux32 linux64 mim adduser fsfreeze seedrng bc setserial \
    zcat bzcat lzcat xzcat unlzop lzopcat \
    i2ctransfer start-stop-daemon run-init resume nuke freeramdisk \
    hexedit od shred install setpriv nologin passwd fold md5sum paste \
    nproc unix2dos truncate mesg tsort dos2unix expr logname who ts \
    unlink logname killall5 chroot poweroff halt \
    egrep fgrep link base32 nice arch; do
    for applet_dir in bin sbin usr/bin usr/sbin; do
        applet_path="$target_dir/$applet_dir/$applet"
        if test -L "$applet_path"; then
            case "$(readlink "$applet_path")" in
                *busybox) rm -f "$applet_path" ;;
            esac
        fi
    done
done

grep -q '^mtd0[[:space:]]\+/[[:space:]]\+romfs[[:space:]]\+ro,noauto' "$fstab"
test "$(grep -c '[[:space:]]ramfs[[:space:]]' "$fstab")" -eq 3
! grep -q 'remount,rw /' "$inittab"
