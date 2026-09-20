//
//  GPSLabLocalizationCore.c
//  GPSLab
//
//  Embedded bilingual catalog + numeric normalization. UTF-8 source; no
//  Foundation/UIKit/private frameworks. Compiled into the dylib and into
//  portable CI tests.
//

#include "GPSLabLocalizationCore.h"

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* --- Catalog --- */

const GPSLabLocalizationEntry kGPSLabLocalizationTable[] = {
    // Common
    { "common.ok", "\u062d\u0633\u0646\u064b\u0627", "OK" },
    { "common.cancel", "\u0625\u0644\u063a\u0627\u0621", "Cancel" },
    { "common.close", "\u0625\u063a\u0644\u0627\u0642", "Close" },
    { "common.save", "\u062d\u0641\u0638", "Save" },
    { "common.rename", "\u0625\u0639\u0627\u062f\u0629 \u062a\u0633\u0645\u064a\u0629", "Rename" },
    { "common.delete", "\u062d\u0630\u0641", "Delete" },
    { "common.clear", "\u0645\u0633\u062d", "Clear" },
    { "common.apply", "\u062a\u0637\u0628\u064a\u0642", "Apply" },
    { "common.name", "\u0627\u0644\u0627\u0633\u0645", "Name" },
    { "common.done", "\u062a\u0645", "Done" },

    // Overlay canvas
    { "overlay.title", "GPSLab", "GPSLab" },
    { "overlay.enabled", "\u0645\u064f\u0641\u0639\u0651\u0644", "Enabled" },
    { "overlay.disabled", "\u0645\u064f\u0639\u0637\u0651\u0644", "Disabled" },
    { "overlay.status.format", "%@ | %.5f, %.5f | %.0f \u0645", "%@ | %.5f, %.5f | %.0f m" },
    { "overlay.engine.enabled", "\u062a\u0645 \u062a\u0641\u0639\u064a\u0644 \u0627\u0644\u0645\u062d\u0631\u0643", "Engine enabled" },
    { "overlay.engine.disabled", "\u062a\u0645 \u062a\u0639\u0637\u064a\u0644 \u0627\u0644\u0645\u062d\u0631\u0643", "Engine disabled" },
    { "overlay.search.placeholder", "\u0627\u0628\u062d\u062b \u0639\u0646 \u0639\u0646\u0648\u0627\u0646 \u0623\u0648 \u0645\u0643\u0627\u0646", "Search address or place" },
    { "overlay.pick.start", "\u0627\u0636\u063a\u0637 \u0639\u0644\u0649 \u0627\u0644\u062e\u0631\u064a\u0637\u0629 \u0644\u062a\u062d\u062f\u064a\u062f \u0628\u062f\u0627\u064a\u0629 \u0627\u0644\u0645\u0633\u0627\u0631", "Tap the map to set the route start" },
    { "overlay.pick.end", "\u0627\u0636\u063a\u0637 \u0639\u0644\u0649 \u0627\u0644\u062e\u0631\u064a\u0637\u0629 \u0644\u062a\u062d\u062f\u064a\u062f \u0646\u0647\u0627\u064a\u0629 \u0627\u0644\u0645\u0633\u0627\u0631", "Tap the map to set the route end" },
    { "overlay.annotation.synthetic", "\u0627\u0641\u062a\u0631\u0627\u0636\u064a", "Synthetic" },
    { "overlay.annotation.real", "\u062d\u0642\u064a\u0642\u064a (\u063a\u064a\u0631 \u0645\u062d\u0627\u0643\u0649)", "Real (not spoofed)" },
    { "overlay.accessibility.center", "\u0627\u0644\u062a\u0648\u0633\u064a\u0637 \u0639\u0644\u0649 \u0627\u0644\u0645\u0631\u0633\u0627\u0629", "Center on anchor" },
    { "overlay.accessibility.favorites", "\u0627\u0644\u0645\u0641\u0636\u0644\u0629", "Favorites" },
    { "overlay.accessibility.route", "\u0627\u0644\u0645\u0633\u0627\u0631", "Route" },
    { "overlay.accessibility.settings", "\u0627\u0644\u062e\u064a\u0627\u0631\u0627\u062a", "Options" },

    // Options / settings
    { "options.title", "\u0627\u0644\u062e\u064a\u0627\u0631\u0627\u062a", "Options" },
    { "options.manual", "\u0625\u062d\u062f\u0627\u062b\u064a\u0627\u062a \u064a\u062f\u0648\u064a\u0629...", "Manual coordinate..." },
    { "options.recents", "\u0627\u0644\u0645\u0648\u0627\u0642\u0639 \u0627\u0644\u0623\u062e\u064a\u0631\u0629...", "Recents..." },
    { "options.fluctuation", "\u062a\u063a\u064a\u0651\u0631 \u0627\u0644\u0645\u0648\u0642\u0639...", "Location fluctuation..." },
    { "options.section.anchor", "\u0627\u0644\u0645\u0631\u0633\u0627\u0629", "Anchor" },
    { "options.section.preferences", "\u0627\u0644\u062a\u0641\u0636\u064a\u0644\u0627\u062a", "Preferences" },
    { "options.section.mapStyle", "\u0646\u0645\u0637 \u0627\u0644\u062e\u0631\u064a\u0637\u0629", "Map style" },
    { "options.section.language", "\u0627\u0644\u0644\u063a\u0629", "Language" },
    { "options.section.subscription", "\u0627\u0644\u0627\u0634\u062a\u0631\u0627\u0643", "Subscription" },
    { "options.keepLast", "\u0627\u0644\u0627\u062d\u062a\u0641\u0627\u0638 \u0628\u0622\u062e\u0631 \u0625\u062d\u062f\u0627\u062b\u064a\u0627\u062a", "Keep last coordinate" },
    { "options.realLocation", "\u0625\u0638\u0647\u0627\u0631 \u0645\u0648\u0642\u0639 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 \u0627\u0644\u062d\u0642\u064a\u0642\u064a", "Show real user location" },
    { "options.language.arabic", "\u0627\u0644\u0639\u0631\u0628\u064a\u0629", "\u0627\u0644\u0639\u0631\u0628\u064a\u0629" },
    { "options.language.english", "English", "English" },
    { "map.style.standard", "\u0642\u064a\u0627\u0633\u064a", "Standard" },
    { "map.style.hybrid", "\u0645\u0631\u0643\u0651\u0628", "Hybrid" },
    { "map.style.satellite", "\u0642\u0645\u0631 \u0635\u0646\u0627\u0639\u064a", "Satellite" },
    { "subscription.grace", "\u0627\u0644\u0627\u0634\u062a\u0631\u0627\u0643 \u0646\u0634\u0637 (\u0641\u062a\u0631\u0629 \u0633\u0645\u0627\u062d). \u062c\u062f\u0651\u062f \u0642\u0631\u064a\u0628\u064b\u0627 \u0644\u062a\u062c\u0646\u0651\u0628 \u0627\u0644\u0627\u0646\u0642\u0637\u0627\u0639.", "Subscription active (grace period). Renew soon to avoid interruption." },

    // Favorites
    { "favorites.title", "\u0627\u0644\u0645\u0641\u0636\u0644\u0629", "Favorites" },
    { "favorites.add", "\u0625\u0636\u0627\u0641\u0629 \u0645\u0641\u0636\u0644\u0629", "Add favorite" },
    { "favorites.defaultName", "\u0645\u0641\u0636\u0644\u0629", "Favorite" },
    { "favorites.rename", "\u0625\u0639\u0627\u062f\u0629 \u062a\u0633\u0645\u064a\u0629 \u0627\u0644\u0645\u0641\u0636\u0644\u0629", "Rename favorite" },
    { "favorites.empty", "\u0644\u0627 \u062a\u0648\u062c\u062f \u0645\u0641\u0636\u0644\u0627\u062a \u0628\u0639\u062f. \u0627\u0636\u063a\u0637 + \u0644\u0625\u0636\u0627\u0641\u0629 \u0648\u0627\u062d\u062f\u0629.", "No favorites yet. Tap + to add one." },
    { "favorites.accessibility.add", "\u0625\u0636\u0627\u0641\u0629 \u0645\u0641\u0636\u0644\u0629", "Add favorite" },

    // Recents
    { "recents.title", "\u0627\u0644\u0645\u0648\u0627\u0642\u0639 \u0627\u0644\u0623\u062e\u064a\u0631\u0629", "Recents" },
    { "recents.clear", "\u0645\u0633\u062d", "Clear" },
    { "recents.clear.title", "\u0645\u0633\u062d \u0627\u0644\u0645\u0648\u0627\u0642\u0639 \u0627\u0644\u0623\u062e\u064a\u0631\u0629", "Clear recents" },
    { "recents.clear.message", "\u0625\u0632\u0627\u0644\u0629 \u0643\u0644 \u0627\u0644\u0645\u0648\u0627\u0642\u0639 \u0627\u0644\u0623\u062e\u064a\u0631\u0629\u061f", "Remove every recent anchor?" },
    { "recents.cell.title", "\u062d\u062f\u064a\u062b", "Recent" },
    { "recents.empty", "\u0644\u0627 \u062a\u0648\u062c\u062f \u0625\u062d\u062f\u0627\u062b\u064a\u0627\u062a \u062d\u062f\u064a\u062b\u0629 \u0628\u0639\u062f.", "No recent coordinates yet." },
    { "recents.accessibility.delete", "\u062d\u0630\u0641", "Delete" },

    // Manual entry
    { "manual.title", "\u0625\u062d\u062f\u0627\u062b\u064a\u0627\u062a \u064a\u062f\u0648\u064a\u0629", "Manual coordinate" },
    { "manual.latitude", "\u062e\u0637 \u0627\u0644\u0639\u0631\u0636", "Latitude" },
    { "manual.longitude", "\u062e\u0637 \u0627\u0644\u0637\u0648\u0644", "Longitude" },
    { "manual.altitude", "\u0627\u0644\u0627\u0631\u062a\u0641\u0627\u0639 (\u0645)", "Altitude (m)" },
    { "manual.heading", "\u0627\u0644\u0627\u062a\u062c\u0627\u0647 (\u062f\u0631\u062c\u0629 \u0623\u0648 -1)", "Course (deg or -1)" },
    { "manual.invalid.title", "\u0625\u062d\u062f\u0627\u062b\u064a\u0627\u062a \u063a\u064a\u0631 \u0635\u0627\u0644\u062d\u0629", "Invalid coordinate" },
    { "manual.invalid.message", "\u064a\u062c\u0628 \u0623\u0646 \u064a\u0643\u0648\u0646 \u062e\u0637 \u0627\u0644\u0639\u0631\u0636 \u0628\u064a\u0646 90-\u0648 90 \u0648\u062e\u0637 \u0627\u0644\u0637\u0648\u0644 \u0628\u064a\u0646 180-\u0648 180.", "Latitude must be -90..90 and longitude -180..180." },
    { "manual.invalid.number", "\u0623\u062f\u062e\u0644 \u0631\u0642\u0645\u064b\u0627 \u0635\u0627\u0644\u062d\u064b\u0627.", "Enter a valid number." },

    // Route
    { "route.title", "\u0627\u0644\u0645\u0633\u0627\u0631", "Route" },
    { "route.mode.driving", "\u0642\u064a\u0627\u062f\u0629", "Driving" },
    { "route.mode.walking", "\u0645\u0634\u064a", "Walking" },
    { "route.mode.cycling", "\u062f\u0631\u0627\u062c\u0629", "Cycling" },
    { "route.mode.custom", "\u0645\u062e\u0635\u0635", "Custom" },
    { "route.customSpeed", "\u0633\u0631\u0639\u0629 \u0645\u062e\u0635\u0635\u0629 (\u0643\u0645/\u0633)", "Custom speed (km/h)" },
    { "route.speedsInfo", "\u0627\u0644\u0633\u0631\u0639\u0627\u062a: \u0645\u0634\u064a 5 | \u062f\u0631\u0627\u062c\u0629 15 | \u0642\u064a\u0627\u062f\u0629 50 \u0643\u0645/\u0633. \u0627\u0644\u0645\u062e\u0635\u0635 \u064a\u0633\u062a\u062e\u062f\u0645 \u0627\u0644\u0642\u064a\u0645\u0629 \u0623\u062f\u0646\u0627\u0647.", "Speeds: Walking 5 | Cycling 15 | Driving 50 km/h. Custom uses the value below." },
    { "route.setStart", "\u062a\u062d\u062f\u064a\u062f \u0627\u0644\u0628\u062f\u0627\u064a\u0629 \u0639\u0644\u0649 \u0627\u0644\u062e\u0631\u064a\u0637\u0629", "Set start on map" },
    { "route.setEnd", "\u062a\u062d\u062f\u064a\u062f \u0627\u0644\u0646\u0647\u0627\u064a\u0629 \u0639\u0644\u0649 \u0627\u0644\u062e\u0631\u064a\u0637\u0629", "Set end on map" },
    { "route.startLabel", "\u0627\u0644\u0628\u062f\u0627\u064a\u0629: \u063a\u064a\u0631 \u0645\u062d\u062f\u062f\u0629", "Start: not set" },
    { "route.endLabel", "\u0627\u0644\u0646\u0647\u0627\u064a\u0629: \u063a\u064a\u0631 \u0645\u062d\u062f\u062f\u0629", "End: not set" },
    { "route.startLabel.format", "\u0627\u0644\u0628\u062f\u0627\u064a\u0629: %@", "Start: %@" },
    { "route.endLabel.format", "\u0627\u0644\u0646\u0647\u0627\u064a\u0629: %@", "End: %@" },
    { "route.notSet", "\u063a\u064a\u0631 \u0645\u062d\u062f\u062f\u0629", "not set" },
    { "route.start", "\u0628\u062f\u0621 \u0627\u0644\u0645\u0633\u0627\u0631", "Start route" },
    { "route.pauseResume", "\u0625\u064a\u0642\u0627\u0641 \u0645\u0624\u0642\u062a / \u0645\u062a\u0627\u0628\u0639\u0629", "Pause / Resume" },
    { "route.stop", "\u0625\u0646\u0647\u0627\u0621 \u0627\u0644\u0645\u0633\u0627\u0631", "Stop route" },
    { "route.section.mode", "\u0627\u0644\u0646\u0645\u0637", "Mode" },
    { "route.section.endpoints", "\u0646\u0642\u0627\u0637 \u0627\u0644\u0628\u062f\u0627\u064a\u0629 \u0648\u0627\u0644\u0646\u0647\u0627\u064a\u0629", "Endpoints" },
    { "route.section.playback", "\u0627\u0644\u062a\u0634\u063a\u064a\u0644", "Playback" },
    { "route.section.onStop", "\u0639\u0646\u062f \u0627\u0644\u0625\u0646\u062a\u0647\u0627\u0621", "On stop" },
    { "route.state.idle", "\u062e\u0627\u0645\u0644", "Idle" },
    { "route.state.loading", "\u062c\u0627\u0631\u064d \u062a\u062d\u0645\u064a\u0644 \u0627\u0644\u0645\u0633\u0627\u0631", "Loading route" },
    { "route.state.playing", "\u0642\u064a\u062f \u0627\u0644\u062a\u0634\u063a\u064a\u0644", "Playing" },
    { "route.state.paused", "\u0645\u062a\u0648\u0642\u0641 \u0645\u0624\u0642\u062a\u064b\u0627", "Paused" },
    { "route.status.format", "%@  %.0f \u0645  %.0f%%", "%@  %.0f m  %.0f%%" },
    { "route.incomplete.title", "\u0627\u0644\u0645\u0633\u0627\u0631 \u063a\u064a\u0631 \u0645\u0643\u062a\u0645\u0644", "Route incomplete" },
    { "route.incomplete.message", "\u062d\u062f\u0651\u062f \u0646\u0642\u0637\u0629 \u0627\u0644\u0628\u062f\u0627\u064a\u0629 \u0648\u0627\u0644\u0646\u0647\u0627\u064a\u0629 \u0623\u0648\u0644\u064b\u0627.", "Set both a start and an end point first." },
    { "route.failed.title", "\u0641\u0634\u0644 \u0627\u0644\u0645\u0633\u0627\u0631", "Route failed" },
    { "route.stop.stay", "\u0627\u0644\u0628\u0642\u0627\u0621 \u0641\u064a \u0627\u0644\u0645\u0648\u0642\u0639 \u0627\u0644\u062d\u0627\u0644\u064a", "Stay at current" },
    { "route.stop.return", "\u0627\u0644\u0639\u0648\u062f\u0629 \u0625\u0644\u0649 \u0627\u0644\u0628\u062f\u0627\u064a\u0629", "Return to start" },
    { "route.annotation.start", "\u0627\u0644\u0628\u062f\u0627\u064a\u0629", "Start" },
    { "route.annotation.end", "\u0627\u0644\u0646\u0647\u0627\u064a\u0629", "End" },

    // Fluctuation
    { "fluctuation.title", "\u062a\u063a\u064a\u0651\u0631 \u0627\u0644\u0645\u0648\u0642\u0639", "Location fluctuation" },
    { "fluctuation.boundedWalk", "\u062d\u0631\u0643\u0629 \u0639\u0634\u0648\u0627\u0626\u064a\u0629 \u0645\u062d\u062f\u0648\u062f\u0629", "Bounded random walk" },
    { "fluctuation.section", "\u0627\u0644\u062a\u063a\u064a\u0651\u0631", "Fluctuation" },
    { "fluctuation.radiusFormat", "%.0f \u0645", "%.0f m" },
    { "fluctuation.radius", "\u0646\u0637\u0627\u0642 \u0627\u0644\u062a\u063a\u064a\u0651\u0631 (\u0645\u062a\u0631)", "Radius (meters)" },

    // Search
    { "search.empty", "\u0644\u0627 \u062a\u0648\u062c\u062f \u0646\u062a\u0627\u0626\u062c", "No results" },

    // Subscription (UI strings only; status is mapped read-only from the enum)
    { "subscription.status.unknown", "\u0627\u0644\u062d\u0627\u0644\u0629 \u063a\u064a\u0631 \u0645\u0639\u0631\u0648\u0641\u0629", "Status unknown" },
    { "subscription.status.checking", "\u062c\u0627\u0631\u064d \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u0627\u0634\u062a\u0631\u0627\u0643...", "Checking subscription..." },
    { "subscription.status.active", "\u0646\u0634\u0637", "Active" },
    { "subscription.status.activeWithPlan", "\u0646\u0634\u0637 - %@", "Active - %@" },
    { "subscription.status.grace", "\u0646\u0634\u0637 (\u0641\u062a\u0631\u0629 \u0633\u0645\u0627\u062d)", "Active (grace period)" },
    { "subscription.status.expired", "\u0627\u0646\u062a\u0647\u0649 \u0627\u0644\u0627\u0634\u062a\u0631\u0627\u0643", "Subscription expired" },
    { "subscription.status.invalid", "\u0627\u0644\u0627\u0634\u062a\u0631\u0627\u0643 \u063a\u064a\u0631 \u0635\u0627\u0644\u062d \u0639\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632", "Subscription not valid on this device" },
    { "subscription.status.offline", "\u0627\u0644\u0627\u0634\u062a\u0631\u0627\u0643 \u063a\u064a\u0631 \u0645\u062a\u0627\u062d", "Subscription unavailable" },
    { "subscription.plan.none", "\u0627\u0644\u062e\u0637\u0629: -", "Plan: -" },
    { "subscription.plan.format", "\u0627\u0644\u062e\u0637\u0629: %@", "Plan: %@" },
    { "subscription.validUntil", "\u0635\u0627\u0644\u062d \u062d\u062a\u0649 %@", "Valid until %@" },
    { "subscription.noService", "\u0644\u0627 \u064a\u062d\u062a\u0648\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631 \u0639\u0644\u0649 \u062e\u062f\u0645\u0629 \u0627\u0634\u062a\u0631\u0627\u0643 \u0645\u064f\u0647\u064a\u0651\u0623\u0629.", "This build has no subscription service configured." },
    { "subscription.noSignIn", "\u062a\u0633\u062c\u064a\u0644 \u0627\u0644\u062f\u062e\u0648\u0644 \u063a\u064a\u0631 \u0645\u062a\u0627\u062d \u0641\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631.", "Sign in is unavailable in this build." },
    { "subscription.noManage", "\u0625\u062f\u0627\u0631\u0629 \u0627\u0644\u062d\u0633\u0627\u0628 \u063a\u064a\u0631 \u0645\u062a\u0627\u062d\u0629 \u0641\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631.", "Account management is unavailable in this build." },
    { "subscription.activate", "\u062a\u0641\u0639\u064a\u0644", "Activate" },
    { "subscription.signIn", "\u062a\u0633\u062c\u064a\u0644 \u0627\u0644\u062f\u062e\u0648\u0644", "Sign In" },
    { "subscription.restore", "\u0627\u0633\u062a\u0639\u0627\u062f\u0629", "Restore" },
    { "subscription.tryAgain", "\u0625\u0639\u0627\u062f\u0629 \u0627\u0644\u0645\u062d\u0627\u0648\u0644\u0629", "Try Again" },
    { "subscription.manage", "\u0625\u062f\u0627\u0631\u0629 \u0627\u0644\u062d\u0633\u0627\u0628", "Manage Account" },
    { "subscription.codePlaceholder", "\u0631\u0645\u0632 \u0627\u0644\u062a\u0641\u0639\u064a\u0644", "Activation code" },
    { "subscription.activationUnavailable", "\u0627\u0644\u062a\u0641\u0639\u064a\u0644 \u063a\u064a\u0631 \u0645\u062a\u0627\u062d \u0641\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631.", "Activation is not available in this build." },
    { "subscription.activating", "\u062c\u0627\u0631\u064d \u0627\u0644\u062a\u0641\u0639\u064a\u0644...", "Activating..." },
    { "subscription.signInUnavailable", "\u062a\u0633\u062c\u064a\u0644 \u0627\u0644\u062f\u062e\u0648\u0644 \u063a\u064a\u0631 \u0645\u062a\u0627\u062d \u0641\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631.", "Sign in is not available in this build." },
    { "subscription.manageUnavailable", "\u0625\u062f\u0627\u0631\u0629 \u0627\u0644\u062d\u0633\u0627\u0628 \u063a\u064a\u0631 \u0645\u062a\u0627\u062d\u0629 \u0641\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631.", "Account management is not available in this build." },
    { "subscription.restoreUnavailable", "\u0627\u0644\u0627\u0633\u062a\u0639\u0627\u062f\u0629 \u063a\u064a\u0631 \u0645\u062a\u0627\u062d\u0629 \u0641\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631.", "Restore is not available in this build." },
    { "subscription.restoring", "\u062c\u0627\u0631\u064d \u0627\u0644\u0627\u0633\u062a\u0639\u0627\u062f\u0629...", "Restoring..." },
    { "subscription.retryUnavailable", "\u0625\u0639\u0627\u062f\u0629 \u0627\u0644\u0645\u062d\u0627\u0648\u0644\u0629 \u063a\u064a\u0631 \u0645\u062a\u0627\u062d\u0629 \u0641\u064a \u0647\u0630\u0627 \u0627\u0644\u0625\u0635\u062f\u0627\u0631.", "Retry is not available in this build." },
    { "subscription.checkingNow", "\u062c\u0627\u0631\u064d \u0627\u0644\u062a\u062d\u0642\u0642...", "Checking..." },
};

const size_t kGPSLabLocalizationTableCount =
    sizeof(kGPSLabLocalizationTable) / sizeof(kGPSLabLocalizationTable[0]);

/* --- Language resolution --- */

GPSLabLanguageCode GPSLabLanguageResolve(const char *stored) {
    if (stored == NULL) {
        return GPSLabLanguageArabic;
    }
    while (*stored == ' ' || *stored == '\t') {
        stored += 1;
    }
    if ((stored[0] == 'e' || stored[0] == 'E') && (stored[1] == 'n' || stored[1] == 'N')) {
        char next = stored[2];
        if (next == '\0' || next == '-' || next == '_') {
            return GPSLabLanguageEnglish;
        }
    }
    return GPSLabLanguageArabic;
}

const char *GPSLabLanguageIdentifier(GPSLabLanguageCode language) {
    return language == GPSLabLanguageEnglish ? "en" : "ar";
}

const char *GPSLabLocalizationLookup(const char *key, GPSLabLanguageCode language) {
    if (key == NULL) {
        return NULL;
    }
    for (size_t index = 0; index < kGPSLabLocalizationTableCount; index++) {
        const GPSLabLocalizationEntry *entry = &kGPSLabLocalizationTable[index];
        if (strcmp(entry->key, key) == 0) {
            if (language == GPSLabLanguageEnglish) {
                return entry->english;
            }
            return entry->arabic;
        }
    }
    return NULL;
}

/* --- Numeric normalization --- */

static size_t gpslab_utf8_decode(const unsigned char *bytes, size_t length, size_t offset,
                                 unsigned int *codepoint) {
    unsigned char first = bytes[offset];
    if (first < 0x80) {
        *codepoint = first;
        return 1;
    }
    if ((first & 0xE0) == 0xC0 && offset + 1 < length) {
        *codepoint = ((unsigned int)(first & 0x1F) << 6) | (unsigned int)(bytes[offset + 1] & 0x3F);
        return 2;
    }
    if ((first & 0xF0) == 0xE0 && offset + 2 < length) {
        *codepoint = ((unsigned int)(first & 0x0F) << 12) |
                     ((unsigned int)(bytes[offset + 1] & 0x3F) << 6) |
                     (unsigned int)(bytes[offset + 2] & 0x3F);
        return 3;
    }
    if ((first & 0xF8) == 0xF0 && offset + 3 < length) {
        *codepoint = ((unsigned int)(first & 0x07) << 18) |
                     ((unsigned int)(bytes[offset + 1] & 0x3F) << 12) |
                     ((unsigned int)(bytes[offset + 2] & 0x3F) << 6) |
                     (unsigned int)(bytes[offset + 3] & 0x3F);
        return 4;
    }
    *codepoint = first;
    return 1;
}

static int gpslab_is_ignorable_bidi(unsigned int codepoint) {
    // LRM, RLM, ALM, embedding/override, isolates.
    if (codepoint == 0x200E || codepoint == 0x200F || codepoint == 0x061C) {
        return 1;
    }
    if (codepoint >= 0x202A && codepoint <= 0x202E) {
        return 1;
    }
    if (codepoint >= 0x2066 && codepoint <= 0x2069) {
        return 1;
    }
    return 0;
}

size_t GPSLabLocalizationNormalizeNumeric(const char *input, char *output, size_t outputSize) {
    if (input == NULL || output == NULL || outputSize == 0) {
        return (size_t)-1;
    }
    const unsigned char *bytes = (const unsigned char *)input;
    size_t length = strlen(input);
    size_t written = 0;
    size_t offset = 0;

    while (offset < length) {
        unsigned int codepoint = 0;
        size_t consumed = gpslab_utf8_decode(bytes, length, offset, &codepoint);
        offset += consumed;

        if (codepoint >= 0x0660 && codepoint <= 0x0669) {
            codepoint = (unsigned int)('0' + (codepoint - 0x0660));
        } else if (codepoint >= 0x06F0 && codepoint <= 0x06F9) {
            codepoint = (unsigned int)('0' + (codepoint - 0x06F0));
        } else if (codepoint == 0x066B) {
            codepoint = (unsigned int)'.';
        } else if (codepoint == 0x066C) {
            continue; // Arabic thousands separator: drop it.
        } else if (codepoint == 0x2212) {
            codepoint = (unsigned int)'-';
        } else if (codepoint == 0x00A0) {
            codepoint = (unsigned int)' ';
        } else if (gpslab_is_ignorable_bidi(codepoint)) {
            continue;
        }

        if (codepoint < 0x80) {
            if (written + 1 >= outputSize) {
                return (size_t)-1;
            }
            output[written++] = (char)codepoint;
        } else if (codepoint < 0x800) {
            if (written + 2 >= outputSize) {
                return (size_t)-1;
            }
            output[written++] = (char)(0xC0 | (codepoint >> 6));
            output[written++] = (char)(0x80 | (codepoint & 0x3F));
        } else if (codepoint < 0x10000) {
            if (written + 3 >= outputSize) {
                return (size_t)-1;
            }
            output[written++] = (char)(0xE0 | (codepoint >> 12));
            output[written++] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
            output[written++] = (char)(0x80 | (codepoint & 0x3F));
        } else {
            if (written + 4 >= outputSize) {
                return (size_t)-1;
            }
            output[written++] = (char)(0xF0 | (codepoint >> 18));
            output[written++] = (char)(0x80 | ((codepoint >> 12) & 0x3F));
            output[written++] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
            output[written++] = (char)(0x80 | (codepoint & 0x3F));
        }
    }

    output[written] = '\0';
    return written;
}

/* --- Strict numeric parsing --- */

int GPSLabLocalizationParseNumber(const char *input, double *output) {
    if (input == NULL || output == NULL) {
        return 0;
    }

    char normalized[128];
    size_t normalizedLength = GPSLabLocalizationNormalizeNumeric(input, normalized, sizeof(normalized));
    if (normalizedLength == (size_t)-1) {
        return 0;
    }

    // Trim ASCII whitespace around the token.
    size_t start = 0;
    while (start < normalizedLength && isspace((unsigned char)normalized[start])) {
        start += 1;
    }
    size_t end = normalizedLength;
    while (end > start && isspace((unsigned char)normalized[end - 1])) {
        end -= 1;
    }
    if (end == start) {
        return 0;
    }

    // Reject any character outside the ASCII numeric grammar. This rejects
    // "nan"/"inf", hex floats and other strtod extensions before parsing.
    int sawDigit = 0;
    int sawExponent = 0;
    for (size_t index = start; index < end; index++) {
        char character = normalized[index];
        if (character >= '0' && character <= '9') {
            sawDigit = 1;
        } else if (character == '+' || character == '-' || character == '.') {
            continue;
        } else if ((character == 'e' || character == 'E') && !sawExponent) {
            sawExponent = 1;
        } else {
            return 0;
        }
    }
    if (!sawDigit) {
        return 0;
    }

    // strtod needs a NUL-terminated slice; copy the trimmed token.
    char token[128];
    size_t tokenLength = end - start;
    if (tokenLength >= sizeof(token)) {
        return 0;
    }
    memcpy(token, normalized + start, tokenLength);
    token[tokenLength] = '\0';

    errno = 0;
    char *parseEnd = NULL;
    double value = strtod(token, &parseEnd);
    if (parseEnd == token || parseEnd == NULL || *parseEnd != '\0') {
        return 0;
    }
    if (errno == ERANGE || !isfinite(value)) {
        return 0;
    }

    *output = value;
    return 1;
}
