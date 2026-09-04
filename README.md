# STM32F429 afboot, initramfs, and framebuffer layout

This branch uses Buildroot's small `afboot` loader. Linux executes directly
from internal Flash, while the Buildroot root filesystem is embedded in the
kernel as an initramfs. The kernel command line, `root=/dev/ram`, comes from
the DTB's `/chosen/bootargs`; afboot does not synthesize it.

The branch-local fragments enable the STM32 LTDC DRM driver, SPI5 panel
initialization, the ILI9341 panel driver, and DRM fbdev emulation. Runtime PM
is enabled because the LTDC driver needs it to ungate the pixel clock. The
serial console remains on USART1; `/dev/fb0` is available without the much
larger framebuffer-console stack.

| Flash range | Purpose |
| --- | --- |
| `0x08000000-0x08003fff` | afboot, maximum 16 KiB |
| `0x08004000-0x0800bfff` | Linux DTB, maximum 32 KiB |
| `0x0800c000-0x081fffff` | execute-in-place Linux kernel, embedded initramfs, and free growth space |

These boundaries follow the STM32F429 Flash erase sectors. Buildroot
configures both afboot and Linux to use `0x0800c000` as the XIP kernel
address. The build checks that `xipImage` does not exceed the 2,048,000 bytes
available between that address and the end of the 2 MiB Flash.

The complete Buildroot `fb-test-app` package does not fit: its five static
bFLT executables produce a 2,300,480-byte `xipImage`, 252,480 bytes beyond
the Flash limit. The framebuffer image without that package is 1,978,444
bytes and leaves 69,556 bytes. Installing only the main 66,584-byte
`fb-test` executable produces a 2,045,515-byte image and leaves only 2,485
bytes, so even that is too tight to be a useful student default.

There is no separate rootfs partition and no persistent bootloader
environment. Adding files to the Buildroot target increases `xipImage`; the
build reports the exact remaining Flash margin and rejects overflow.
