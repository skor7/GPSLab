//
//  GPSLabVPNMaskHook.h
//  GPSLab
//
//  In-process VPN interface masking. This is a namespaced, hardening-aware port
//  of the operator's standalone VPNMask (VPNMask-Builder/VPNMask.m): a fishhook
//  rebinding of `getifaddrs` that unlinks tun/utun/ppp/tap/ipsec interfaces from
//  the returned linked list.
//
//  Unlike the standalone artifact it is NOT installed by a dylib constructor and
//  it is NOT unconditional:
//    * it is installed explicitly and idempotently from the GPSLab dylib
//      constructor (via GPSLabSimulationRegistry) so its ordering against the
//      other process-wide hooks is auditable;
//    * the hook obeys the persisted "VPN Simulation" toggle (default Disabled)
//      read from an atomic cache, never from the defaults store inside the hook;
//    * Disabled means a pure pass-through to the captured original.
//
//  The shared Source/fishhook.{c,h} (vendored, byte-identical to the standalone
//  builder copy) is reused; this port adds no second fishhook translation unit.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabVPNMaskHook : NSObject

/**
 * Installs the getifaddrs rebinding exactly once. Seeds the runtime gate from the
 * persisted preference BEFORE rebinding, so the first hooked call already obeys
 * the saved toggle. Returns YES when the rebinding was installed.
 */
+ (BOOL)installHooks;

/**
 * Updates the lock-free runtime gate without touching persistence. Called by
 * GPSLabSimulationRegistry after it writes the preference. Safe from any thread.
 */
+ (void)setRuntimeEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
