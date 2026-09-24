# GPSLab - clean-room injected dylib for authorized iOS testing only.
# arm64 only, iOS 16.0+, ARC, no hooking frameworks, no external dependencies.

ARCHS = arm64
TARGET = iphone:clang:latest:16.0

# ---------------------------------------------------------------------------
# Build mode: DEV (default) or PRODUCTION.
#
#   DEV         (default) readable + debuggable: Theos debug schema stays on
#               (DEBUG=1 -> -DDEBUG -O0 -ggdb), full debug symbols, no strip.
#               A plain `make` never produces a hardened release artifact.
#   PRODUCTION  hardened release artifact: hidden visibility, no compiler
#               ident, no DWARF/STABS, no local symbols, NDEBUG (no asserts),
#               plus link-time symbol stripping. Release pipelines must select
#               it explicitly:
#
#                   make MODE=production
#
# The mode -> flag mapping lives in scripts/build_mode.mk so it can be audited
# for BOTH modes without an iOS toolchain (scripts/audit_build_modes.sh). The
# canonical Source/ tree is never modified or obfuscated.
# ---------------------------------------------------------------------------
GPSLAB_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
include $(GPSLAB_ROOT)/scripts/build_mode.mk

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GPSLab

GPSLab_FILES = \
	Source/GPSLabTypes.m \
	Source/GPSLabProfileCore.c \
	Source/GPSLabSelectionPolicyCore.c \
	Source/GPSLabSchedulerCore.c \
	Source/GPSLabLocalizationCore.c \
	Source/GPSLabProtectedStringCore.c \
	Source/GPSLabProtectedString.m \
	Source/GPSLabLocalization.m \
	Source/GPSLabAltitudeViewController.m \
	Source/GPSLabMapLinkCore.c \
	Source/GPSLabMapLinkResolver.m \
	Source/GPSLabMapLinkURLSessionTransport.m \
	Source/GPSLabMasterIntentGuard.m \
	Source/GPSLabModalPolicy.c \
	Source/GPSLabSearchLayoutCore.c \
	Source/GPSLabGeodesy.m \
	Source/GPSLabConfiguration.m \
	Source/GPSLabStore.m \
	Source/GPSLabTheme.m \
	Source/GPSLabProfile.m \
	Source/GPSLabProfileStore.m \
	Source/GPSLabSimulationModule.m \
	Source/GPSLabWiFiSimulationModule.m \
	Source/GPSLabBluetoothSimulationModule.m \
	Source/GPSLabSimulationRegistry.m \
	Source/GPSLabBluetoothRuntime.m \
	Source/GPSLabWiFiRuntime.m \
	Source/GPSLabProfileApplicationCoordinator.m \
	Source/GPSLabEngineProfileBackend.m \
	Source/GPSLabScheduler.m \
	Source/GPSLabSchedulerDefaultHost.m \
	Source/GPSLabProfilesPanelView.m \
	Source/GPSLabProfileFormViewController.m \
	Source/GPSLabSimulationSettingsViewController.m \
	Source/GPSLabScheduleViewController.m \
	Source/GPSLabDriftModel.m \
	Source/GPSLabLocationFactory.m \
	Source/GPSLabRouteSimulator.m \
	Source/GPSLabEngine.m \
	Source/LocationStream.m \
	Source/CoreLocationHooks.m \
	Source/Diagnostics.m \
	Source/GPSLabStatusLog.m \
	Source/GPSLabLicenseConfig.m \
	Source/GPSLabSecureStore.m \
	Source/GPSLabTokenVerifier.m \
	Source/GPSLabEntitlement.m \
	Source/GPSLabLicenseManager.m \
	Source/GPSLabSubscriptionViewController.m \
	Source/GPSLabModalCoordinator.m \
	Source/GPSLabSheetViewController.m \
	Source/GPSLabSearchResultsViewController.m \
	Source/GPSLabManualEntryViewController.m \
	Source/GPSLabFluctuationViewController.m \
	Source/GPSLabFavoritesViewController.m \
	Source/GPSLabRecentsViewController.m \
	Source/GPSLabRouteViewController.m \
	Source/GPSLabOptionsViewController.m \
	Source/GPSLabOverlayViewController.m \
	Source/GPSLabOverlayPresenter.m \
	Source/GPSLabPrimaryInterface.m \
	Source/GPSLabGestureActivator.m \
	Source/GPSLabRuntime.m \
	Source/dylib_init.m

GPSLab_CFLAGS = -fobjc-arc -Wall -Wextra $(GPSLAB_MODE_CFLAGS)
GPSLab_LDFLAGS = $(GPSLAB_MODE_LDFLAGS)
GPSLab_FRAMEWORKS = Foundation CoreLocation UIKit MapKit Security CoreBluetooth NetworkExtension

GPSLab_INSTALL_PATH = @executable_path/Frameworks

include $(THEOS_MAKE_PATH)/library.mk
