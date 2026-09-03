# STM32F429 afboot, ROMFS, and framebuffer flash layout

This branch adds the on-board LTDC/ILI9341 framebuffer, keeps the small
Buildroot `afboot` loader, and stores the root filesystem separately from the
execute-in-place Linux kernel. The custom DTB mounts ROMFS as `mtd0`.

| Flash range | Purpose |
| --- | --- |
| `0x08000000-0x08003fff` | afboot, maximum 16 KiB |
| `0x08004000-0x0800bfff` | Linux DTB, maximum 32 KiB |
| `0x0800c000-0x0819ffff` | execute-in-place Linux kernel and kernel growth |
| `0x081a0000-0x081fffff` | exact read-only ROMFS partition, 384 KiB |

The boundaries follow the STM32F429 Flash erase sectors. afboot occupies the
first 16 KiB sector, the DTB uses the next two sectors, and Linux starts at
`0x0800c000`, as required by the Buildroot afboot configuration. Starting the
ROMFS at `0x081a0000` leaves the last three 128 KiB sectors for the rootfs.

The DT maps the complete 2 MiB internal Flash as the parent `mtd-rom` device,
then describes the ROMFS as a fixed partition at relative offset `0x1a0000`
with size `0x060000`. The full-size parent is deliberate: a direct physmap
whose size is not a power of two can be rounded down by `map_rom`. The fixed
child preserves the exact 384 KiB partition and appears as `mtd0`.

The trimmed framebuffer ROMFS is 347,136 bytes, leaving 46,080 bytes for
additions. Its branch-local BusyBox fragment removes unused storage, SCSI,
checksum, xattr, runit-control, and miscellaneous applets.
This framebuffer variant therefore demonstrates the display but is not the
recommended base for student exercises that need to add files. The build
reports the current headroom and rejects kernel/ROMFS overlap.
