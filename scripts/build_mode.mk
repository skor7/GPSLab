# GPSLab build-mode mapping.
#
# Included by the top-level Makefile BEFORE $(THEOS)/makefiles/common.mk, so the
# DEBUG value here is the one Theos honors. This fragment is deliberately
# self-contained (no Theos include, no iOS toolchain): scripts/audit_build_modes.sh
# evaluates BOTH modes with plain GNU make and asserts the exact flag sets, so a
# regression in either mode fails the static gate without a build.
#
# Two explicit modes:
#
#   dev        (DEFAULT) readable, debuggable development build.
#                        DEBUG=1 keeps Theos' debug schema (-DDEBUG, -O0, -ggdb),
#                        so the artifact carries full debug symbols, assertions
#                        and diagnostics. A plain `make` therefore NEVER produces
#                        a hardened release artifact.
#
#   production            hardened release artifact.
#                        DEBUG=0 removes the debug schema; the extra flags remove
#                        the remaining symbol, ident and debug/assert surface:
#                          -fvisibility=hidden  only exported ObjC classes stay
#                                               visible (no internal C ABI leak)
#                          -fno-ident           no compiler identification string
#                          -g0                  no DWARF/STABS (no source paths)
#                          -DNDEBUG             no assert/NSAssert strings
#                          -DGPSLAB_PRODUCTION=1 selects the production branch of
#                                               GPSLabProtectedString.h: protected
#                                               client literals are runtime-decoded
#                                               instead of compiled in verbatim
#                          -Wl,-x -Wl,-S        strip local + debug symbols
#
# Select explicitly for a release build:
#
#   make MODE=production
#
# The canonical Source/ tree is never modified or obfuscated: hardening is
# entirely build-time and applies only to the production artifact.

MODE ?= dev

# Accept either case, reject anything else (a typo must fail the build rather
# than silently fall through to a hardened or unhardened artifact).
GPSLAB_MODE_VALUES := dev DEV production PRODUCTION
ifeq ($(filter $(MODE),$(GPSLAB_MODE_VALUES)),)
$(error Invalid MODE '$(MODE)': expected 'dev' (default) or 'production')
endif

ifneq ($(filter $(MODE),dev DEV),)
# ---------------------------------------------------------------- DEV --------
# Readable + debuggable: keep the Theos debug schema, add no hardening flags and
# no link-time stripping. GPSLAB_MODE_* are consumed by the top-level Makefile.
DEBUG = 1
GPSLAB_MODE_CFLAGS =
GPSLAB_MODE_LDFLAGS =
GPSLAB_MODE_SELECTED = dev
else
# ----------------------------------------------------------- PRODUCTION ------
DEBUG = 0
GPSLAB_MODE_CFLAGS = -fvisibility=hidden -fno-ident -g0 -DNDEBUG -DGPSLAB_PRODUCTION=1
GPSLAB_MODE_LDFLAGS = -Wl,-x -Wl,-S
GPSLAB_MODE_SELECTED = production
endif
