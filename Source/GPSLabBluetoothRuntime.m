//
//  GPSLabBluetoothRuntime.m
//  GPSLab
//
//  Host-app-only CoreBluetooth simulation for authorized QA. When disabled,
//  every intercepted selector forwards to the captured public CoreBluetooth IMP.
//

#import "GPSLabBluetoothRuntime.h"

#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "GPSLabSimulationRegistry.h"

static CBManagerState (*gOriginalState)(id, SEL) = NULL;
static BOOL (*gOriginalIsScanning)(id, SEL) = NULL;
static void (*gOriginalScan)(id, SEL, NSArray<CBUUID *> *, NSDictionary<NSString *, id> *) = NULL;
static void (*gOriginalStopScan)(id, SEL) = NULL;
static void (*gOriginalConnect)(id, SEL, CBPeripheral *, NSDictionary<NSString *, id> *) = NULL;
static void (*gOriginalCancel)(id, SEL, CBPeripheral *) = NULL;

static const void *kGPSLabFakePeripheralMarker = &kGPSLabFakePeripheralMarker;
static const void *kGPSLabFakePeripheralIdentifier = &kGPSLabFakePeripheralIdentifier;
static const void *kGPSLabFakePeripheralName = &kGPSLabFakePeripheralName;
static const void *kGPSLabFakePeripheralState = &kGPSLabFakePeripheralState;

static uint64_t GPSLabFNV1a64(NSData *data, uint64_t seed) {
    uint64_t hash = seed;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSUUID *GPSLabDeterministicUUID(NSString *seedString) {
    NSData *data = [seedString dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint64_t a = GPSLabFNV1a64(data, 1469598103934665603ULL);
    uint64_t b = GPSLabFNV1a64(data, 1099511628211ULL);
    uint8_t bytes[16];
    for (NSUInteger i = 0; i < 8; i++) bytes[i] = (uint8_t)(a >> ((7 - i) * 8));
    for (NSUInteger i = 0; i < 8; i++) bytes[8 + i] = (uint8_t)(b >> ((7 - i) * 8));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    uuid_t uuidBytes;
    memcpy(uuidBytes, bytes, 16);
    return [[NSUUID alloc] initWithUUIDBytes:uuidBytes];
}

static NSUUID *GPSLabFakeIdentifier(id self, SEL _cmd) {
    (void)_cmd;
    return objc_getAssociatedObject(self, kGPSLabFakePeripheralIdentifier);
}

static NSString *GPSLabFakeName(id self, SEL _cmd) {
    (void)_cmd;
    return objc_getAssociatedObject(self, kGPSLabFakePeripheralName);
}

static CBPeripheralState GPSLabFakeState(id self, SEL _cmd) {
    (void)_cmd;
    NSNumber *state = objc_getAssociatedObject(self, kGPSLabFakePeripheralState);
    return state != nil ? (CBPeripheralState)state.integerValue : CBPeripheralStateDisconnected;
}

static Class GPSLabFakePeripheralClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class base = NSClassFromString(@"CBPeripheral");
        if (base == Nil) return;
        cls = objc_allocateClassPair(base, "GPSLabSyntheticCBPeripheral", 0);
        if (cls == Nil) {
            cls = NSClassFromString(@"GPSLabSyntheticCBPeripheral");
            return;
        }
        class_addMethod(cls, @selector(identifier), (IMP)GPSLabFakeIdentifier, "@@:");
        class_addMethod(cls, @selector(name), (IMP)GPSLabFakeName, "@@:");
        class_addMethod(cls, @selector(state), (IMP)GPSLabFakeState, "q@:");
        objc_registerClassPair(cls);
    });
    return cls;
}

static BOOL GPSLabIsFakePeripheral(id peripheral) {
    return [objc_getAssociatedObject(peripheral, kGPSLabFakePeripheralMarker) boolValue];
}

static NSData *GPSLabHexData(NSString *string) {
    NSString *hex = [[[string ?: @"" stringByReplacingOccurrencesOfString:@" " withString:@""]
                      stringByReplacingOccurrencesOfString:@":" withString:@""]
                     stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if (hex.length == 0 || (hex.length % 2) != 0 || hex.length > 512) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    if ([hex rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    for (NSUInteger i = 0; i < hex.length; i += 2) {
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
        if (![scanner scanHexInt:&value]) return nil;
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
    }
    return data;
}

static NSDictionary *GPSLabPatternObject(NSString *pattern) {
    NSData *data = [pattern dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0 || data.length > 16384) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSArray<NSDictionary *> *GPSLabPeripheralSpecs(void) {
    GPSLabProfileBluetoothConfig *config = [GPSLabSimulationRegistry activeBluetoothConfig];
    if (config == nil) return @[];

    NSDictionary *root = GPSLabPatternObject(config.pattern);
    NSArray *peripherals = [root[@"peripherals"] isKindOfClass:[NSArray class]] ? root[@"peripherals"] : nil;
    if (peripherals.count > 0) {
        NSMutableArray *valid = [NSMutableArray array];
        for (id item in [peripherals subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)8, peripherals.count))]) {
            if ([item isKindOfClass:[NSDictionary class]]) [valid addObject:item];
        }
        if (valid.count > 0) return valid;
    }

    return @[@{
        @"localName": config.deviceName ?: @"GPSLab BLE",
        @"rssi": @(config.rssi),
        @"connectable": @YES,
    }];
}

static BOOL GPSLabPoweredOn(void) {
    GPSLabProfileBluetoothConfig *config = [GPSLabSimulationRegistry activeBluetoothConfig];
    NSDictionary *root = GPSLabPatternObject(config.pattern);
    id value = root[@"poweredOn"];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

static NSArray<CBUUID *> *GPSLabServiceUUIDs(NSDictionary *spec) {
    NSArray *values = [spec[@"serviceUUIDs"] isKindOfClass:[NSArray class]] ? spec[@"serviceUUIDs"] : @[];
    NSMutableArray *uuids = [NSMutableArray array];
    for (id value in values) {
        if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) continue;
        @try {
            CBUUID *uuid = [CBUUID UUIDWithString:(NSString *)value];
            if (uuid != nil) [uuids addObject:uuid];
        } @catch (__unused NSException *exception) {}
        if (uuids.count >= 16) break;
    }
    return uuids;
}

static BOOL GPSLabMatchesFilter(NSArray<CBUUID *> *filter, NSArray<CBUUID *> *services) {
    if (filter.count == 0) return YES;
    for (CBUUID *wanted in filter) {
        for (CBUUID *candidate in services) {
            if ([wanted isEqual:candidate]) return YES;
        }
    }
    return NO;
}

static CBPeripheral *GPSLabCreatePeripheral(NSDictionary *spec, NSUInteger index) {
    Class cls = GPSLabFakePeripheralClass();
    if (cls == Nil) return nil;
    id peripheral = [[cls alloc] init];
    if (peripheral == nil) return nil;

    NSString *name = [spec[@"localName"] isKindOfClass:[NSString class]] ? spec[@"localName"] : @"GPSLab BLE";
    NSString *uuidString = [spec[@"uuid"] isKindOfClass:[NSString class]] ? spec[@"uuid"] : nil;
    NSUUID *uuid = uuidString.length > 0 ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
    if (uuid == nil) {
        GPSLabProfileBluetoothConfig *config = [GPSLabSimulationRegistry activeBluetoothConfig];
        uuid = GPSLabDeterministicUUID([NSString stringWithFormat:@"%@|%@|%lu",
                                        config.profileName ?: @"GPSLab", name, (unsigned long)index]);
    }

    objc_setAssociatedObject(peripheral, kGPSLabFakePeripheralMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(peripheral, kGPSLabFakePeripheralIdentifier, uuid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(peripheral, kGPSLabFakePeripheralName, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(peripheral, kGPSLabFakePeripheralState, @(CBPeripheralStateDisconnected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return peripheral;
}

static void GPSLabDeliverDiscovery(CBCentralManager *manager, NSArray<CBUUID *> *filter) {
    if (![GPSLabSimulationRegistry isBluetoothEnabled] || !GPSLabPoweredOn()) return;
    id<CBCentralManagerDelegate> delegate = manager.delegate;
    SEL selector = @selector(centralManager:didDiscoverPeripheral:advertisementData:RSSI:);
    if (delegate == nil || ![delegate respondsToSelector:selector]) return;

    NSArray<NSDictionary *> *specs = GPSLabPeripheralSpecs();
    NSUInteger index = 0;
    for (NSDictionary *spec in specs) {
        NSArray<CBUUID *> *services = GPSLabServiceUUIDs(spec);
        if (!GPSLabMatchesFilter(filter, services)) {
            index++;
            continue;
        }
        CBPeripheral *peripheral = GPSLabCreatePeripheral(spec, index++);
        if (peripheral == nil) continue;

        NSString *name = [spec[@"localName"] isKindOfClass:[NSString class]] ? spec[@"localName"] : peripheral.name;
        NSInteger rssi = [spec[@"rssi"] isKindOfClass:[NSNumber class]]
            ? [spec[@"rssi"] integerValue]
            : [GPSLabSimulationRegistry activeBluetoothConfig].rssi;
        rssi = MAX(-100, MIN(0, rssi));

        NSMutableDictionary *advertisement = [NSMutableDictionary dictionary];
        if (name.length > 0) advertisement[CBAdvertisementDataLocalNameKey] = name;
        if (services.count > 0) advertisement[CBAdvertisementDataServiceUUIDsKey] = services;
        if ([spec[@"connectable"] isKindOfClass:[NSNumber class]]) {
            advertisement[CBAdvertisementDataIsConnectable] = @([spec[@"connectable"] boolValue]);
        } else {
            advertisement[CBAdvertisementDataIsConnectable] = @YES;
        }
        if ([spec[@"manufacturerData"] isKindOfClass:[NSString class]]) {
            NSData *manufacturer = GPSLabHexData(spec[@"manufacturerData"]);
            if (manufacturer.length > 0) advertisement[CBAdvertisementDataManufacturerDataKey] = manufacturer;
        }

        ((void (*)(id, SEL, CBCentralManager *, CBPeripheral *, NSDictionary *, NSNumber *))objc_msgSend)
            (delegate, selector, manager, peripheral, advertisement, @(rssi));
    }
}

static CBManagerState GPSLabCentralState(id self, SEL _cmd) {
    if ([GPSLabSimulationRegistry isBluetoothEnabled]) {
        return GPSLabPoweredOn() ? CBManagerStatePoweredOn : CBManagerStatePoweredOff;
    }
    return gOriginalState != NULL ? gOriginalState(self, _cmd) : CBManagerStateUnknown;
}

static BOOL GPSLabCentralIsScanning(id self, SEL _cmd) {
    if ([GPSLabSimulationRegistry isBluetoothEnabled]) return YES;
    return gOriginalIsScanning != NULL ? gOriginalIsScanning(self, _cmd) : NO;
}

static void GPSLabCentralScan(id self, SEL _cmd, NSArray<CBUUID *> *services, NSDictionary *options) {
    if (![GPSLabSimulationRegistry isBluetoothEnabled]) {
        if (gOriginalScan != NULL) gOriginalScan(self, _cmd, services, options);
        return;
    }
    (void)options;
    dispatch_async(dispatch_get_main_queue(), ^{
        GPSLabDeliverDiscovery((CBCentralManager *)self, services);
    });
}

static void GPSLabCentralStopScan(id self, SEL _cmd) {
    if ([GPSLabSimulationRegistry isBluetoothEnabled]) return;
    if (gOriginalStopScan != NULL) gOriginalStopScan(self, _cmd);
}

static void GPSLabCentralConnect(id self, SEL _cmd, CBPeripheral *peripheral, NSDictionary *options) {
    if (![GPSLabSimulationRegistry isBluetoothEnabled] || !GPSLabIsFakePeripheral(peripheral)) {
        if (gOriginalConnect != NULL) gOriginalConnect(self, _cmd, peripheral, options);
        return;
    }
    (void)options;
    objc_setAssociatedObject(peripheral, kGPSLabFakePeripheralState, @(CBPeripheralStateConnected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<CBCentralManagerDelegate> delegate = [(CBCentralManager *)self delegate];
    SEL selector = @selector(centralManager:didConnectPeripheral:);
    if ([delegate respondsToSelector:selector]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, CBCentralManager *, CBPeripheral *))objc_msgSend)
                (delegate, selector, (CBCentralManager *)self, peripheral);
        });
    }
}

static void GPSLabCentralCancel(id self, SEL _cmd, CBPeripheral *peripheral) {
    if (![GPSLabSimulationRegistry isBluetoothEnabled] || !GPSLabIsFakePeripheral(peripheral)) {
        if (gOriginalCancel != NULL) gOriginalCancel(self, _cmd, peripheral);
        return;
    }
    objc_setAssociatedObject(peripheral, kGPSLabFakePeripheralState, @(CBPeripheralStateDisconnected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<CBCentralManagerDelegate> delegate = [(CBCentralManager *)self delegate];
    SEL selector = @selector(centralManager:didDisconnectPeripheral:error:);
    if ([delegate respondsToSelector:selector]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, CBCentralManager *, CBPeripheral *, NSError *))objc_msgSend)
                (delegate, selector, (CBCentralManager *)self, peripheral, nil);
        });
    }
}

static BOOL GPSLabReplaceInstanceMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return NO;
    if (original != NULL) *original = method_getImplementation(method);
    return class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method)) != NULL ||
           method_getImplementation(class_getInstanceMethod(cls, selector)) == replacement;
}

@implementation GPSLabBluetoothRuntime

+ (BOOL)installHooks {
    static dispatch_once_t onceToken;
    static BOOL installed = NO;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"CBCentralManager");
        if (cls == Nil) return;
        BOOL ok = YES;
        ok &= GPSLabReplaceInstanceMethod(cls, @selector(state), (IMP)GPSLabCentralState, (IMP *)&gOriginalState);
        ok &= GPSLabReplaceInstanceMethod(cls, @selector(isScanning), (IMP)GPSLabCentralIsScanning, (IMP *)&gOriginalIsScanning);
        ok &= GPSLabReplaceInstanceMethod(cls, @selector(scanForPeripheralsWithServices:options:), (IMP)GPSLabCentralScan, (IMP *)&gOriginalScan);
        ok &= GPSLabReplaceInstanceMethod(cls, @selector(stopScan), (IMP)GPSLabCentralStopScan, (IMP *)&gOriginalStopScan);
        ok &= GPSLabReplaceInstanceMethod(cls, @selector(connectPeripheral:options:), (IMP)GPSLabCentralConnect, (IMP *)&gOriginalConnect);
        ok &= GPSLabReplaceInstanceMethod(cls, @selector(cancelPeripheralConnection:), (IMP)GPSLabCentralCancel, (IMP *)&gOriginalCancel);
        installed = ok;
    });
    return installed;
}

@end
