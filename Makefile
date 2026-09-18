# GPSLab - clean-room injected dylib for authorized iOS testing only.
# arm64 only, iOS 16.0+, ARC, no UI, no hooking frameworks.

ARCHS = arm64
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GPSLab

GPSLab_FILES = \
	Source/GPSLabEngine.m \
	Source/CoreLocationHooks.m \
	Source/LocationStream.m \
	Source/Diagnostics.m \
	Source/dylib_init.m

GPSLab_CFLAGS = -fobjc-arc
GPSLab_FRAMEWORKS = Foundation CoreLocation UIKit

# Canonical Theos way to set the dylib install name. The library template expands
# `TARGET_LDFLAGS_DYNAMICLIB` as `-dynamiclib -install_name "$(LOCAL_INSTALL_PATH)/$(1)"`
# where `LOCAL_INSTALL_PATH` comes from `<instance>_INSTALL_PATH`. This produces
# `-install_name @executable_path/Frameworks/GPSLab.dylib` with no duplicate LDFLAGS.
GPSLab_INSTALL_PATH = @executable_path/Frameworks

include $(THEOS_MAKE_PATH)/library.mk
