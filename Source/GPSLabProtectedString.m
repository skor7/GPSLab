//
//  GPSLabProtectedString.m
//  GPSLab
//
//  Foundation wrapper over the pure C XOR decode. Only the PRODUCTION macro
//  references this function; a DEV build expands GPSLAB_PROTECTED_STRING to the
//  plaintext literal and never links here.
//

#import "GPSLabProtectedString.h"

#import "GPSLabProtectedStringCore.h"

#import <stdlib.h>
#import <string.h>

NSString * _Nullable GPSLabProtectedStringDecode(const unsigned char *blob,
                                                 NSUInteger length,
                                                 unsigned char key) {
    if (blob == NULL || length == 0) {
        return nil;
    }

    unsigned char *buffer = (unsigned char *)malloc((size_t)length);
    if (buffer == NULL) {
        return nil;
    }

    GPSLabProtectedStringDecodeBytes(blob, (size_t)length, key, buffer);
    NSString *value = [[NSString alloc] initWithBytes:buffer
                                               length:(NSUInteger)length
                                             encoding:NSUTF8StringEncoding];
    // Do not leave the decoded bytes on the heap longer than necessary.
    memset(buffer, 0, (size_t)length);
    free(buffer);
    return value;
}
