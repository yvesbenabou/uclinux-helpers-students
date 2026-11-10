#!/bin/sh
# REPLACES Buildroot's board/qemu/post-image.sh on this helpers branch.
# Upstream generates images/start-qemu.sh from its template/board README for
# direct Linux + ext2. Here we COPY our tracked launcher for initramfs/U-Boot.
# Buildroot's original generator is not called; its source tree is unchanged.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install -m 0755 "$script_dir/start-qemu.sh" "$BINARIES_DIR/start-qemu.sh"
