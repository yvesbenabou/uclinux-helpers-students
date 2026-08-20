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
