# STM32F429 U-Boot flash layout

U-Boot is built by Buildroot from its pinned `2025.07` source. Linux remains
an execute-in-place kernel; the `uImage` header is at `0x08040000` and its
payload, linked for `0x08040040`, follows immediately.

| Flash range | Purpose |
| --- | --- |
| `0x08000000-0x0801ffff` | U-Boot, maximum 128 KiB |
| `0x08020000-0x0803ffff` | persistent U-Boot environment sector |
| `0x08040000-...` | U-Boot legacy `uImage` |
| `0x08180000-...` | ROMFS root filesystem |
| `0x081fb000-0x081fffff` | Linux DTB, maximum 20 KiB |

`run_openocd_stm32.sh flash` preserves the environment sector. Pass
`--reset-env` to erase it deliberately. At the U-Boot prompt, changes become
persistent only after `saveenv`:

```text
setenv student_name Alice
saveenv
reset
printenv student_name
```

The reference build reports at least 100 KiB between the current ROMFS image
and the DTB for student rootfs growth. The build warns as that space is used
and rejects only an actual overlap.
