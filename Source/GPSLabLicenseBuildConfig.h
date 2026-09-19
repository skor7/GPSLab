//
//  GPSLabLicenseBuildConfig.h
//  GPSLab
//
//  Optional GPSLab build-time license configuration, independent of the host app.
//  This is the recommended way to point a specific GPSLab build at a backend without
//  editing the host Info.plist; a packaging script can generate this header.
//
//  Everything is EMPTY by default (fail closed). Define values here, replace this
//  header at build time, or pass -D flags:
//
//    -DGPSLAB_LICENSE_BUILD_ENDPOINT=\"https://license.example.com/v1/entitlement\"
//
//  NEVER place a signing PRIVATE key here. Only the public verification key belongs
//  in a build.
//

#ifndef GPSLAB_LICENSE_BUILD_CONFIG_H
#define GPSLAB_LICENSE_BUILD_CONFIG_H

// #define GPSLAB_LICENSE_BUILD_ENDPOINT    @"https://license.example.com/v1/entitlement"
// #define GPSLAB_LICENSE_BUILD_PUBLIC_KEY  @"<base64 DER SubjectPublicKeyInfo or raw X9.63 point>"
// #define GPSLAB_LICENSE_BUILD_SIGN_IN_URL @"https://example.com/signin"
// #define GPSLAB_LICENSE_BUILD_MANAGE_URL  @"https://example.com/account"
// #define GPSLAB_LICENSE_BUILD_ISSUER      @"gpslab"
// #define GPSLAB_LICENSE_BUILD_AUDIENCE    @"com.gpslab.runtime"
// #define GPSLAB_LICENSE_BUILD_SKEW_SECONDS 300
// #define GPSLAB_LICENSE_BUILD_GRACE_SECONDS 604800

#endif /* GPSLAB_LICENSE_BUILD_CONFIG_H */
