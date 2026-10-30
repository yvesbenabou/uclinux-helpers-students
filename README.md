# STM32F429 afboot and initramfs flash layout

This branch uses Buildroot's small `afboot` loader. Linux executes directly
from internal Flash, while the Buildroot root filesystem is embedded in the
kernel as an initramfs. The kernel command line, `root=/dev/ram`, comes from
the DTB's `/chosen/bootargs`; afboot does not synthesize it.

| Flash range | Purpose |
| --- | --- |
| `0x08000000-0x08003fff` | afboot, maximum 16 KiB |
| `0x08004000-0x0800bfff` | Linux DTB, maximum 32 KiB |
| `0x0800c000-0x081fffff` | execute-in-place Linux kernel, embedded initramfs, and free growth space |

These boundaries follow the STM32F429 Flash erase sectors. afboot occupies
the first 16 KiB sector. The DTB starts in the next sector and has 32 KiB
before the kernel. Buildroot configures both afboot and Linux to use
`0x0800c000` as the XIP kernel address, so the generated `xipImage` can be
written there without relocation.

There is no separate rootfs partition: adding files to the Buildroot target
increases `xipImage`, and the remaining Flash after that image is the student
growth margin. There is also no persistent bootloader environment; boot
addresses and the kernel command line are deliberately fixed by the
Buildroot configuration and DTB, keeping the student boot path small.

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
