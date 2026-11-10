#!/bin/sh
# Install the course launcher instead of Buildroot's direct-Linux/ext2 example.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install -m 0755 "$script_dir/start-qemu.sh" "$BINARIES_DIR/start-qemu.sh"
