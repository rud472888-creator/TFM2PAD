#pragma once
#import <UIKit/UIKit.h>
#include <stdatomic.h>

// Adapted from AgePad AppPresence.h. This observes only this UIKit process;
// it never queries other applications or global keyboard/mouse idle time.
static _Atomic BOOL TFMSteamPresenceKnown;
static _Atomic BOOL TFMSteamAppActive;
static _Atomic double TFMSteamInactiveSince;

__attribute__((constructor)) static void TFMSteamObserveAppPresence(void) {
    void (^observe)(void)=^{
        BOOL active=UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
        atomic_store(&TFMSteamAppActive,active);
        atomic_store(&TFMSteamInactiveSince,NSProcessInfo.processInfo.systemUptime);
        atomic_store(&TFMSteamPresenceKnown,YES);
        NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *notification) {
            atomic_store(&TFMSteamAppActive,YES); atomic_store(&TFMSteamPresenceKnown,YES);
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *notification) {
            atomic_store(&TFMSteamInactiveSince,NSProcessInfo.processInfo.systemUptime);
            atomic_store(&TFMSteamAppActive,NO); atomic_store(&TFMSteamPresenceKnown,YES);
        }];
    };
    if (NSThread.isMainThread) observe(); else dispatch_async(dispatch_get_main_queue(),observe);
}

static inline BOOL TFMSteamOwnAppIsActive(void) {
    return atomic_load(&TFMSteamPresenceKnown) && atomic_load(&TFMSteamAppActive);
}
