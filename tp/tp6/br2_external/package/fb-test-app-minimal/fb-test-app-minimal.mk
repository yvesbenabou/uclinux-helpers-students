################################################################################
#
# fb-test-app-minimal
#
################################################################################

FB_TEST_APP_MINIMAL_VERSION = 1.0
FB_TEST_APP_MINIMAL_SITE = $(BR2_EXTERNAL_UCLINUX_TP_PATH)/package/fb-test-app-minimal/src
FB_TEST_APP_MINIMAL_SITE_METHOD = local

# fb-test-app must have installed its binaries before cleanup.
FB_TEST_APP_MINIMAL_DEPENDENCIES = fb-test-app

define FB_TEST_APP_MINIMAL_INSTALL_TARGET_CMDS
	rm -f $(TARGET_DIR)/usr/bin/fb-test-offset
	rm -f $(TARGET_DIR)/usr/bin/fb-test-rect
	rm -f $(TARGET_DIR)/usr/bin/fb-test-string

endef

$(eval $(generic-package))
