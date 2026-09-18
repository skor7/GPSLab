//
//  Diagnostics.h
//  GPSLab
//
//  os_log-only diagnostics. No real (user) data is ever logged.
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

/** Logs that spoofing is active and the anchor that is being used. */
void GPSLabDiagSpoofActive(double latitude, double longitude, double altitude);

/** Logs a freshly generated synthetic coordinate (safe: it is not real data). */
void GPSLabDiagGeneratedCoordinate(double latitude, double longitude, double altitude);

NS_ASSUME_NONNULL_END
