#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <net/if.h>
#import "fishhook.h"

static int (*orig_getifaddrs)(struct ifaddrs **ifap);

static BOOL is_vpn_interface(const char *name) {
    if (!name) return NO;
    if (strncmp(name, "tun", 3) == 0 ||
        strncmp(name, "utun", 4) == 0 ||
        strncmp(name, "ppp", 3) == 0 ||
        strncmp(name, "tap", 3) == 0 ||
        strncmp(name, "ipsec", 5) == 0) {
        return YES;
    }
    return NO;
}

static int my_getifaddrs(struct ifaddrs **ifap) {
    int ret = orig_getifaddrs(ifap);
    if (ret != 0 || ifap == NULL || *ifap == NULL) {
        return ret;
    }

    struct ifaddrs *curr = *ifap;
    struct ifaddrs *prev = NULL;

    while (curr != NULL) {
        if (is_vpn_interface(curr->ifa_name)) {
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

__attribute__((constructor))
static void init_vpn_mask(void) {
    struct rebinding rebindings[] = {
        {"getifaddrs", (void *)my_getifaddrs, (void **)&orig_getifaddrs}
    };
    rebind_symbols(rebindings, sizeof(rebindings) / sizeof(struct rebinding));
}
