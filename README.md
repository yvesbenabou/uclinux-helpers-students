

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
