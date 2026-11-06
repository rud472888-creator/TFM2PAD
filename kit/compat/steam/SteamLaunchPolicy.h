#ifndef TFM_STEAM_LAUNCH_POLICY_H
#define TFM_STEAM_LAUNCH_POLICY_H

#import <Foundation/Foundation.h>

// A signed personal bundle may opt into the online game route for an ordinary
// icon launch. Any explicit toolkit argument keeps its existing diagnostic
// semantics; neither argv nor the process environment is rewritten here.
static inline BOOL TFMSteamIconOnlineLaunchRequested(void) {
    for (NSString *argument in NSProcessInfo.processInfo.arguments)
        if ([argument hasPrefix:@"--tfm-"]) return NO;
    id mode=NSBundle.mainBundle.infoDictionary[@"TFMPersonalLaunchMode"];
    return [mode isKindOfClass:NSString.class] && [mode isEqualToString:@"steam-online"];
}

static inline BOOL TFMSteamCombinedLaunchRequested(void) {
    return [NSProcessInfo.processInfo.arguments containsObject:@"--tfm-play-with-steam"] ||
        TFMSteamIconOnlineLaunchRequested();
}

static inline BOOL TFMSteamSDKClientOrderFixRequested(void) {
    return [NSProcessInfo.processInfo.arguments containsObject:@"--tfm-sdk-client-order-fix"] ||
        TFMSteamIconOnlineLaunchRequested();
}

#endif
