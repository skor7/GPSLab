//
//  GPSLabMapLinkURLSessionTransportTesting.h
//  GPSLab
//
//  Test-visible declaration of the per-request delegate so tests can drive the
//  REAL delegate methods (redirect rejection, exactly-once completion, late
//  cancellation suppression) without a live network session.
//

#import "GPSLabMapLinkURLSessionTransport.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabMapLinkURLSessionRequest : NSObject <NSURLSessionDataDelegate>

/**
 * Test seam: builds a request with no session/task. Calling the delegate methods
 * directly (with nil session/task) exercises the production redirect/completion
 * logic; `cancel` suppresses the completion.
 */
- (instancetype)initForTestingWithCompletion:(GPSLabMapLinkTransportCompletion)completion;

/** Cancels the request; a cancelled request never invokes its completion. */
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
