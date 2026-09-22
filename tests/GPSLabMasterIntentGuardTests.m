//
//  GPSLabMasterIntentGuardTests.m
//  GPSLab
//
//  Foundation tests for the exact guard the overlay uses to decide whether an
//  asynchronous profile apply/stage completion still owns the master switch.
//  Covers: double enabled-profile apply (stale failure must not roll back the
//  newer switch), manual switch change during an async apply, current-intent
//  success, and current-intent failure without a switch change.
//
//  Build/run (macOS):
//    clang -fobjc-arc -fmodules -framework Foundation -ISource \
//      tests/GPSLabMasterIntentGuardTests.m Source/GPSLabMasterIntentGuard.m \
//      -o /tmp/gpslab-master-intent-guard-tests
//    /tmp/gpslab-master-intent-guard-tests
//

#import <Foundation/Foundation.h>

#import "GPSLabMasterIntentGuard.h"

static int gFailures = 0;
static int gChecks = 0;

#define CHECK(condition, message)                                  \
    do {                                                           \
        gChecks++;                                                 \
        if (!(condition)) {                                        \
            gFailures++;                                           \
            fprintf(stderr, "FAIL: %s\n", [(message) UTF8String]); \
        }                                                          \
    } while (0)

int main(void) {
    @autoreleasepool {
        // 1) Double enabled-profile apply: A is superseded by B.
        GPSLabMasterIntentGuard *guard = [[GPSLabMasterIntentGuard alloc] init];
        NSUInteger a = [guard beginIntent];
        CHECK([guard isCurrentIntent:a], @"first intent is current");
        NSUInteger b = [guard beginIntent];
        CHECK(![guard isCurrentIntent:a], @"second intent supersedes the first");
        CHECK([guard resolveIntent:a applied:NO switchWasChanged:YES] == GPSLabMasterIntentResolutionIgnoreStale,
              @"a stale/cancelled failure must NOT roll back the newer switch");
        CHECK([guard resolveIntent:b applied:NO switchWasChanged:YES] == GPSLabMasterIntentResolutionRollback,
              @"the current intent's failure rolls back the switch it changed");

        // 2) A current-intent success is Applied.
        NSUInteger c = [guard beginIntent];
        CHECK([guard resolveIntent:c applied:YES switchWasChanged:YES] == GPSLabMasterIntentResolutionApplied,
              @"current success is Applied");

        // 3) A current-intent failure that did not change the switch only reports.
        NSUInteger d = [guard beginIntent];
        CHECK([guard resolveIntent:d applied:NO switchWasChanged:NO] == GPSLabMasterIntentResolutionFailureNoChange,
              @"failure without a switch change does not roll back");

        // 4) A manual switch change during an async apply invalidates that apply.
        NSUInteger e = [guard beginIntent];
        [guard invalidateIntents];
        CHECK([guard resolveIntent:e applied:NO switchWasChanged:YES] == GPSLabMasterIntentResolutionIgnoreStale,
              @"a manual switch change makes a pending apply stale");
        CHECK([guard resolveIntent:e applied:YES switchWasChanged:YES] == GPSLabMasterIntentResolutionIgnoreStale,
              @"a stale success is also ignored (never mutates newer state)");

        // 5) A zero token is never current.
        CHECK(![guard isCurrentIntent:0], @"zero token is never current");
    }

    if (gFailures == 0) {
        printf("GPSLabMasterIntentGuardTests: %d checks passed\n", gChecks);
        return 0;
    }
    fprintf(stderr, "GPSLabMasterIntentGuardTests: %d/%d checks failed\n", gFailures, gChecks);
    return 1;
}
