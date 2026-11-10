

## QEMU: U-Boot and ext2

QEMU still emulates ARM VExpress, not the STM32 board. On this branch it
boots U-Boot, then Linux, with the existing `rootfs.ext2` SD root disk.
ROMFS is deliberately STM32-only; the QEMU root filesystem remains ext2.

QEMU builds U-Boot 2025.07 for `vexpress_ca9x4`, not the STM32 binary. It
preloads `zImage` at `0x62000000` and the Linux DTB at `0x63000000` into RAM.
The readable `qemu/uboot.fragment` sets a three-second interruptible countdown
and the default boot command:

```sh
setenv bootargs console=ttyAMA0,115200 rootwait root=/dev/mmcblk0
bootz 0x62000000 - 0x63000000
```

U-Boot does not load these files from the SD card in this first exercise,
and its environment is not persistent (`saveenv` is not provided). The STM32
U-Boot configuration, Flash addresses and environment remain unchanged.

```sh
./3_uclinux_qemu_dl_and_build.sh --quiet
./run_qemu_image.sh
```

The tracked `qemu/start-qemu.sh` is installed into `images/` by the post-image
hook. It reads the effective Buildroot `.config`; it does not guess the boot
mode from leftover image files. Changing target files requires a complete
Buildroot `make` (script 3), not just compiling Linux.

For an output prepared on this same branch before this change, back up any
custom configuration, then remove **only** `~/uclinux/outputs/qemu/.config`
once and run script 3. This invokes the normal QEMU-only reset. STM32 outputs
and STM32 boot/flash scripts are unchanged.

## Switching helpers branches


Each target output records its prepared Git branch in `.helpers-branch`, for
example `~/uclinux/outputs/stm32/.helpers-branch`. Setup (step 2) and builds
(steps 3 and 4) use the same preparation function in `uclinux_common.sh`.

On the same branch, with an existing Buildroot `.config`, preparation does
nothing and the build is incremental. Changing branches, deleting `.config`,
or using an output without a marker regenerates the branch configuration and
resets Linux and BusyBox (also U-Boot when selected). The first build recompiles
those packages. Downloads, host tools, the cross-toolchain and sysroot survive.

The reset also deletes the generated `target/`, `images/` and rootfs assembly
directory. It invalidates target-package configuration and target/image
installation stamps so Buildroot regenerates its package-file accounting and
reinstalls the selected packages. Target packages can be rebuilt during this
step; host packages keep their stamps. Put source
files in a versioned project and deploy through package rules or a post-build
script: manual additions inside `target/` are discarded on a branch change.

The marker is written after preparation, before compilation, so a failed build
can resume without another reset. Git switching itself runs no hook. Updates
within the same branch do not trigger a reset; this mechanism does not track
same-branch changes to kernel patches or configuration fragments.

On driver-course branches, `driver.sh build` calls the same preparation
function before applying the selected lab profile. Inspection commands never
reset the output. Driver sources remain in the separate student repository.

A branch reset drops Buildroot's remembered external package tree unless
`BR2_EXTERNAL` is supplied explicitly. On an unchanged branch, its remembered
external tree and package selections remain available.
