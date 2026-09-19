//
//  Diagnostics.h
//  GPSLab
//
//  os_log-only diagnostics with a STRICT allow-list. Allowed events:
//    dylib loaded, hooks installed, overlay opened/closed, engine enabled/disabled,
//    route started/stopped, license check started / license state changed, and an
//    internal error by stable numeric code only.
//
//  Never logged: coordinates, search queries, tokens, entitlement/installation ids,
//  account data, URLs, NSError.localizedDescription or any host data.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Logs that the dylib constructor ran. */
void GPSLabDiagDylibLoaded(void);

/** Logs how many CoreLocation selectors were intercepted. */
void GPSLabDiagHooksInstalled(int hookCount);

/** Logs the engine enable/disable transition (no coordinates). */
void GPSLabDiagEngineEnabled(BOOL enabled);

/** Logs the overlay presenter lifecycle. */
void GPSLabDiagOverlayOpened(void);
void GPSLabDiagOverlayClosed(void);

/** Logs route simulation start/stop. No route geometry is logged. */
void GPSLabDiagRouteStarted(void);
void GPSLabDiagRouteStopped(void);

/** Logs that a subscription check started. No payload or identifiers are logged. */
void GPSLabDiagLicenseCheckStarted(void);

/** Logs a license state change by numeric code only (never ids or messages). */
void GPSLabDiagLicenseStateChanged(NSInteger stateCode);

/** Logs an internal error by stable numeric code only (no dynamic text). */
void GPSLabDiagInternalError(NSInteger code);

NS_ASSUME_NONNULL_END
