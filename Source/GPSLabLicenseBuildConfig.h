//
//  GPSLabLicenseBuildConfig.h
//  GPSLab
//
//  Optional GPSLab build-time license configuration, independent of the host app.
//  This is the recommended way to point a specific GPSLab build at a backend without
//  editing the host Info.plist; a packaging script can generate this header.
//
//  This build seeds the production endpoint, public verification key, issuer and
//  audience below. The remaining values are empty by default (fail closed). Replace
//  this header at build time, or pass -D flags to override:
//
//    -DGPSLAB_LICENSE_BUILD_ENDPOINT=\"https://license.example.com/v1/entitlement\"
//
//  NEVER place a signing PRIVATE key here. Only the public verification key belongs
//  in a build.
//

#ifndef GPSLAB_LICENSE_BUILD_CONFIG_H
#define GPSLAB_LICENSE_BUILD_CONFIG_H

#define GPSLAB_LICENSE_BUILD_ENDPOINT   @"https://vps-6f128567.vps.ovh.net:8443/api/v1/license/check"
#define GPSLAB_LICENSE_BUILD_PUBLIC_KEY @"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE54r1OAZKf604VWhGWGx6qmNSyldW6dHD69gbgxxlTvCDIWmI987cqZalNJNnyEojQqacigcXQqZTjif2y/KfSw=="
// #define GPSLAB_LICENSE_BUILD_SIGN_IN_URL @"https://example.com/signin"
// #define GPSLAB_LICENSE_BUILD_MANAGE_URL  @"https://example.com/account"
#define GPSLAB_LICENSE_BUILD_ISSUER     @"GPSLab"
#define GPSLAB_LICENSE_BUILD_AUDIENCE   @"GPSLab-iOS"
// #define GPSLAB_LICENSE_BUILD_SKEW_SECONDS 300
// #define GPSLAB_LICENSE_BUILD_GRACE_SECONDS 604800
//
// Web-portal URLs / device endpoints. All are OPTIONAL: when unset, a safe
// same-origin default is derived from GPSLAB_LICENSE_BUILD_ENDPOINT (or the host
// Info.plist endpoint). Any explicit value is rejected unless it is HTTPS, on the
// exact endpoint origin, and free of credentials/identifier query parameters.
// NEVER put a signing key, password or API secret in any of these.
// #define GPSLAB_LICENSE_BUILD_PORTAL_URL        @"https://example.com/account"
// #define GPSLAB_LICENSE_BUILD_TRIAL_URL         @"https://example.com/account/pair"
// #define GPSLAB_LICENSE_BUILD_HELP_URL          @"https://example.com/help"
// #define GPSLAB_LICENSE_BUILD_PAIR_ENDPOINT     @"https://example.com/api/v1/device/pair"
// #define GPSLAB_LICENSE_BUILD_FEEDBACK_ENDPOINT @"https://example.com/api/v1/device/feedback"

#endif /* GPSLAB_LICENSE_BUILD_CONFIG_H */
