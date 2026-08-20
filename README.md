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
