//
//  GPSLabProtectedStringCore.c
//  GPSLab
//
//  Pure C XOR decode for the production-only protected-string facility.
//

#include "GPSLabProtectedStringCore.h"

void GPSLabProtectedStringDecodeBytes(const unsigned char *blob,
                                      size_t length,
                                      unsigned char key,
                                      unsigned char *out) {
    if (blob == NULL || out == NULL) {
        return;
    }
    for (size_t index = 0; index < length; index++) {
        out[index] = (unsigned char)(blob[index] ^ key);
    }
}
