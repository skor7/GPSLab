//
//  GPSLabVPNMaskHook.m
//  GPSLab
//
//  Namespaced, open-source-integrating port of VPNMask-Builder/VPNMask.m.
//
//  Semantics preserved from the standalone source EXACTLY:
//    * the captured original getifaddrs is always called first;
//    * tun/utun/ppp/tap/ipsec prefixes are matched with strncmp on ifa_name;
//    * matching nodes are unlinked (head or middle) and the original return code
//      is returned unchanged;
//    * a non-zero return, a NULL out-param or an empty list is forwarded as-is.
//
//  Deliberate deltas for integration (audited by tests/gpslab_vpn_mask_test.c):
//    * file-static symbols are GPSLab-prefixed so they cannot collide with any
//      other translation unit;
//    * there is NO constructor attribute: the registry installs it explicitly at
//      a known point in the GPSLab dylib constructor, after the persisted state
//      is available and alongside the other process-wide hooks;
//    * it is gated by an atomic runtime flag seeded from the persisted preference
//      and refreshed by +setRuntimeEnabled:; the hook never consults the defaults
//      store (which could re-enter interface enumeration) on the hot path;
//    * the shared Source/fishhook.{c,h} is reused (no duplicate fishhook).
//

#import "GPSLabVPNMaskHook.h"

#import <ifaddrs.h>
#import <net/if.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <string.h>

#import "GPSLabSimulationRegistry.h"
#import "fishhook.h"

// Captured by fishhook when the rebinding is installed.
static int (*gGPSLabOriginalGetifaddrs)(struct ifaddrs **ifap) = NULL;

// Lock-free runtime gate. Initialised to the safe default (Disabled) and seeded
// from the persisted preference at install time. Stores are relaxed: the value is
// an independent BOOL state, never a publication barrier for other data.
static atomic_bool gGPSLabVPNMaskEnabled = false;

// The exact interface prefixes filtered by the standalone VPNMask.
static BOOL GPSLabVPNInterfaceNameMatches(const char *name) {
    if (name == NULL) {
        return NO;
    }
    if (strncmp(name, "tun", 3) == 0 ||
        strncmp(name, "utun", 4) == 0 ||
        strncmp(name, "ppp", 3) == 0 ||
        strncmp(name, "tap", 3) == 0 ||
        strncmp(name, "ipsec", 5) == 0) {
        return YES;
    }
    return NO;
}

static int GPSLabFilteredGetifaddrs(struct ifaddrs **ifap) {
    // Fail safe: without a captured original we cannot forward and must not call
    // the hooked symbol (that would recurse); report the POSIX failure instead.
    if (gGPSLabOriginalGetifaddrs == NULL) {
        return -1;
    }

    // Disabled (the default) is a pure pass-through: the host sees every interface.
    if (!atomic_load_explicit(&gGPSLabVPNMaskEnabled, memory_order_relaxed)) {
        return gGPSLabOriginalGetifaddrs(ifap);
    }

    int ret = gGPSLabOriginalGetifaddrs(ifap);
    if (ret != 0 || ifap == NULL || *ifap == NULL) {
        return ret;
    }

    struct ifaddrs *curr = *ifap;
    struct ifaddrs *prev = NULL;

    while (curr != NULL) {
        if (GPSLabVPNInterfaceNameMatches(curr->ifa_name)) {
            if (prev == NULL) {
                *ifap = curr->ifa_next;
                curr = curr->ifa_next;
            } else {
                prev->ifa_next = curr->ifa_next;
                curr = curr->ifa_next;
            }
        } else {
            prev = curr;
            curr = curr->ifa_next;
        }
    }

    return ret;
}

@implementation GPSLabVPNMaskHook

+ (void)setRuntimeEnabled:(BOOL)enabled {
    atomic_store_explicit(&gGPSLabVPNMaskEnabled, enabled ? true : false, memory_order_relaxed);
}

+ (BOOL)installHooks {
    static dispatch_once_t onceToken;
    static BOOL installed = NO;
    dispatch_once(&onceToken, ^{
        // Seed the gate BEFORE rebinding so a call that races the install already
        // observes the persisted preference rather than the default.
        [self setRuntimeEnabled:[GPSLabSimulationRegistry isVPNEnabled]];

        struct rebinding rebindings[] = {
            {"getifaddrs", (void *)GPSLabFilteredGetifaddrs, (void **)&gGPSLabOriginalGetifaddrs}
        };
        installed = (rebind_symbols(rebindings, sizeof(rebindings) / sizeof(struct rebinding)) == 0);
    });
    return installed;
}

@end
