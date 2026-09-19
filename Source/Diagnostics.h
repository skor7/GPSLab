//
//  Diagnostics.h
//  GPSLab
//
//  os_log-only diagnostics for the events the specification allows:
//  dylib load, hook installation, overlay open/close, engine enable/disable,
//  route start/stop, manager registration and internal errors.
//
//  Coordinates, host application data and real device location are NEVER logged.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Logs that the dylib constructor ran. */
void GPSLabDiagDylibLoaded(void);

/** Logs how many CoreLocation selectors were intercepted. */
void GPSLabDiagHooksInstalled(int hookCount);

/** Logs that a manager started or stopped being tracked. No pointer is logged. */
void GPSLabDiagManagerRegistered(void);
void GPSLabDiagManagerUnregistered(void);

/** Logs that the synthetic engine became active (no anchor values are logged). */
void GPSLabDiagSpoofActive(void);

/** Logs the engine enable/disable transition (no coordinates). */
void GPSLabDiagEngineEnabled(BOOL enabled);

/** Logs that a synthetic location was generated (never its values). */
void GPSLabDiagGeneratedLocation(void);

/** Logs the overlay presenter lifecycle. */
void GPSLabDiagOverlayOpened(void);
void GPSLabDiagOverlayClosed(void);

/** Logs route simulation start/stop. No route geometry is logged. */
void GPSLabDiagRouteStarted(void);
void GPSLabDiagRouteStopped(void);

/** Logs an internal error by stable numeric code only (no dynamic text). */
void GPSLabDiagInternalError(NSInteger code);

NS_ASSUME_NONNULL_END
