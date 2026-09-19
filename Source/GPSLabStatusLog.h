//
//  GPSLabStatusLog.h
//  GPSLab
//
//  A tiny in-memory status line for the overlay. It only ever holds UI-level
//  status strings (no coordinates, no host data) and is backed by os_log already.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPSLabStatusLog : NSObject

+ (instancetype)sharedLog;

/** Appends a short, non-sensitive status message (kept in a bounded ring). */
+ (void)append:(NSString *)message;

/** Most recent message, or nil. */
+ (nullable NSString *)lastMessage;

@end

NS_ASSUME_NONNULL_END
