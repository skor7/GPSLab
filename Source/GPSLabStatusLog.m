//
//  GPSLabStatusLog.m
//  GPSLab
//

#import "GPSLabStatusLog.h"

#import <os/lock.h>

static const NSUInteger kGPSLabStatusLogCapacity = 20;

@implementation GPSLabStatusLog {
    os_unfair_lock _lock;
    NSMutableArray<NSString *> *_messages;
}

+ (instancetype)sharedLog {
    static GPSLabStatusLog *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPSLabStatusLog alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _messages = [NSMutableArray array];
    }
    return self;
}

+ (void)append:(NSString *)message {
    if (message.length == 0) {
        return;
    }
    GPSLabStatusLog *log = [self sharedLog];
    os_unfair_lock_lock(&log->_lock);
    [log->_messages addObject:message];
    while (log->_messages.count > kGPSLabStatusLogCapacity) {
        [log->_messages removeObjectAtIndex:0];
    }
    os_unfair_lock_unlock(&log->_lock);
}

+ (nullable NSString *)lastMessage {
    GPSLabStatusLog *log = [self sharedLog];
    os_unfair_lock_lock(&log->_lock);
    NSString *message = log->_messages.lastObject;
    os_unfair_lock_unlock(&log->_lock);
    return message;
}

@end
