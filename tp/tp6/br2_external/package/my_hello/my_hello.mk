################################################################################
#
# my_hello
#
################################################################################

MY_HELLO_VERSION = 1.0
MY_HELLO_SITE = $(BR2_EXTERNAL_UCLINUX_TP_PATH)/package/my_hello/src
MY_HELLO_SITE_METHOD = local
MY_HELLO_CFLAGS = $(filter-out -O%,$(TARGET_CFLAGS)) -Os
define MY_HELLO_BUILD_CMDS
	$(TARGET_CC) $(MY_HELLO_CFLAGS) -o $(@D)/my_hello $(@D)/my_hello.c
endef

define MY_HELLO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/my_hello $(TARGET_DIR)/usr/bin/my_hello
endef

$(eval $(generic-package))
