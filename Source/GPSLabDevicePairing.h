//
//  GPSLabDevicePairing.h
//  GPSLab
//
//  Device-proof client for the two non-license portal calls the app makes
//  directly (never through a web view):
//
//    POST /api/v1/device/pair      {installationId, deviceSecret}
//         -> {code, expiresAt}     one-time code the user types at /account/pair
//    POST /api/v1/device/feedback  {installationId, deviceSecret, category, message}
//
//  The device secret is a per-installation 32-byte value from the Keychain
//  (GPSLabSecureStore), separate from license material. It is only ever placed
//  in the JSON request BODY under HTTPS to the license-endpoint origin: never in
//  a URL, never in a log.
//
//  Hardening mirrors GPSLabLicenseManager: dedicated serial queue, one in-flight
//  task, explicit redirect rejection, streamed response size cap, bounded
//  request timeout, JSON-only, no identifier/token logging.
//
//  These calls are NOT a license provider and never change entitlement state.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GPSLabDeviceRequestResult) {
    GPSLabDeviceRequestResultSuccess = 0,
    /** No safe same-origin endpoint is configured in this build. */
    GPSLabDeviceRequestResultUnconfigured = 1,
    /** Transport failure or timeout; retryable. */
    GPSLabDeviceRequestResultOffline = 2,
    /** Reached the server but it rejected the request or returned unusable data. */
    GPSLabDeviceRequestResultRejected = 3,
    /** Local input failed validation (empty/oversized message, bad category). */
    GPSLabDeviceRequestResultInvalidInput = 4,
};

@interface GPSLabDevicePairing : NSObject

+ (instancetype)sharedClient;

/** YES when a safe pairing endpoint and a device secret are available. */
- (BOOL)isConfigured;

/**
 * Requests a fresh one-time pairing code. On success `code` is a display-only
 * string (never a URL, never logged). `message` is always a localized,
 * non-technical status. Completion runs on the main queue.
 */
- (void)requestPairingCodeWithCompletion:
    (void (^)(GPSLabDeviceRequestResult result, NSString * _Nullable code, NSString * _Nullable message))completion;

/**
 * Posts bounded feedback under the same device proof. `category` must be one of
 * the fixed portal categories; `message` is truncated on a UTF-8 boundary.
 * Completion runs on the main queue.
 */
- (void)submitFeedbackWithCategory:(NSString *)category
                           message:(NSString *)message
                        completion:(void (^)(GPSLabDeviceRequestResult result, NSString *message))completion;

#pragma mark - Testable payload builders (pure, no network)

/** JSON body for the pairing call, or nil on invalid input. */
+ (nullable NSData *)pairingRequestBodyForInstallation:(NSString *)installationId
                                          deviceSecret:(nullable NSString *)deviceSecret;

/** JSON body for the feedback call, or nil on invalid input. */
+ (nullable NSData *)feedbackRequestBodyForInstallation:(NSString *)installationId
                                           deviceSecret:(nullable NSString *)deviceSecret
                                               category:(NSString *)category
                                                message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
