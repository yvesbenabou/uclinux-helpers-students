# STM32F429 afboot, ROMFS, and framebuffer flash layout

This branch adds the on-board LTDC/ILI9341 framebuffer, keeps the small
Buildroot `afboot` loader, and stores the root filesystem separately from the
execute-in-place Linux kernel. The custom DTB mounts ROMFS as `mtd0`.

Board kernel changes are applied by Buildroot through `BR2_GLOBAL_PATCH_DIR`.
Kernel and BusyBox settings use their respective Buildroot
configuration-fragment variables; the source trees remain unmodified.

| Flash range | Purpose |
| --- | --- |
| `0x08000000-0x08003fff` | afboot, maximum 16 KiB |
| `0x08004000-0x0800bfff` | Linux DTB, maximum 32 KiB |
| `0x0800c000-0x0817ffff` | execute-in-place Linux kernel and kernel growth |
| `0x08180000-0x081fffff` | exact read-only ROMFS partition, 512 KiB |

The boundaries follow the STM32F429 Flash erase sectors. afboot occupies the
first 16 KiB sector, the DTB uses the next two sectors, and Linux starts at
`0x0800c000`, as required by the Buildroot afboot configuration. Starting the
ROMFS at `0x08180000` leaves the last four 128 KiB sectors for the rootfs.

The DT maps the complete 2 MiB internal Flash as the parent `mtd-rom` device,
then describes the ROMFS as a fixed partition at relative offset `0x180000`
with size `0x080000`. The full-size parent is deliberate: a direct physmap
whose size is not a power of two can be rounded down by `map_rom`. The fixed
child preserves the exact 512 KiB partition and appears as `mtd0`.

The trimmed framebuffer ROMFS is 296,960 bytes, leaving 227,328 bytes for
additions. Its branch-local BusyBox fragment removes unused storage, SCSI,
checksum, xattr, runit-control, and miscellaneous applets.
The compact simplefb variant leaves substantial space for student exercises.
The build reports the current headroom and rejects kernel/ROMFS overlap.
