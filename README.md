# STM32F429 afboot and ROMFS flash layout

This branch keeps the small Buildroot `afboot` loader and stores the root
filesystem separately from the execute-in-place Linux kernel. The custom DTB
passes `root=mtd0 rootfstype=romfs ro` to Linux.

| Flash range | Purpose |
| --- | --- |
| `0x08000000-0x08003fff` | afboot, maximum 16 KiB |
| `0x08004000-0x0800bfff` | Linux DTB, maximum 32 KiB |
| `0x0800c000-0x0815ffff` | execute-in-place Linux kernel and kernel growth |
| `0x08160000-0x081fffff` | exact read-only ROMFS partition, 640 KiB |

The boundaries follow the STM32F429 Flash erase sectors. afboot occupies the
first 16 KiB sector, the DTB uses the next two sectors, and Linux starts at
`0x0800c000`, as required by the Buildroot afboot configuration. Starting the
ROMFS at `0x08160000` leaves the last five 128 KiB sectors for the rootfs.

The DT maps the complete 2 MiB internal Flash as the parent `mtd-rom` device,
then describes the ROMFS as a fixed partition at relative offset `0x160000`
with size `0x0a0000`. The full-size parent is deliberate: the previous direct
640 KiB physmap declaration was reduced to 512 KiB by `map_rom`, losing 128
KiB. The fixed child preserves the exact 640 KiB partition and appears as
`mtd0`.

The reference ROMFS is 392,192 bytes, leaving 263,168 bytes (257 KiB) for
student additions, above the 100 KiB target. The build reports the current
headroom and rejects overlap with the end of Flash.

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
