//
//  GPSLabSchedulerDefaultHost.h
//  GPSLab
//
//  Production host for GPSLabScheduler: real clock, dispatch timer, UIApplication
//  foreground state, the engine gate and the application coordinator.
//
//  Split from GPSLabScheduler so the scheduler core stays unit-testable without
//  linking the engine/license stack.
//

#import "GPSLabScheduler.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabSchedulerDefaultHost : NSObject <GPSLabSchedulerHost>

/** The scheduler to call back on a timer wake. Set by the scheduler's init. */
@property (nonatomic, weak, nullable) GPSLabScheduler *scheduler;

@end

NS_ASSUME_NONNULL_END
