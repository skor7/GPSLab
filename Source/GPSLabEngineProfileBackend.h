//
//  GPSLabEngineProfileBackend.h
//  GPSLab
//
//  Production backend for GPSLabProfileApplicationCoordinator. Uses ONLY the
//  existing public GPSLabEngine / GPSLabLicenseManager APIs.
//

#import "GPSLabProfileApplicationCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabEngineProfileBackend : NSObject <GPSLabProfileApplicationBackend>
@end

NS_ASSUME_NONNULL_END
