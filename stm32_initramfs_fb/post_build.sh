#!/bin/sh
# Remove files and stale BusyBox links that have no use on this board.

set -eu

target_dir=$1

# There is no persistent storage across boots for a saved random seed.
rm -f "$target_dir/etc/init.d/S01seedrng"
rm -f "$target_dir/etc/services" "$target_dir/etc/protocols"
rm -f "$target_dir/THIS_IS_NOT_YOUR_ROOT_FILESYSTEM"

for applet in \
    cksum crc32 sha1sum sha256sum sha512sum sha3sum \
    mke2fs mkdosfs getfattr lsscsi partprobe setfattr \
    nl ascii factor fallocate hostid svc svok w uudecode uuencode \
    linux32 linux64 mim adduser fsfreeze seedrng bc setserial \
    zcat bzcat lzcat xzcat unlzop lzopcat \
    i2ctransfer start-stop-daemon run-init resume nuke freeramdisk \
    hexedit od shred install setpriv nologin passwd; do
    for applet_dir in bin sbin usr/bin usr/sbin; do
        applet_path="$target_dir/$applet_dir/$applet"
        if test -L "$applet_path"; then
            case "$(readlink "$applet_path")" in
                *busybox) rm -f "$applet_path" ;;
            esac
        fi
    done
done
