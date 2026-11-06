#import "AppPresence.h"
#include "../UnimplementedBoundary.h"
double TFMSteamSecondsSinceAppActivity(int32_t state,uint32_t type) __asm__("_CGEventSourceSecondsSinceLastEventType");
double TFMSteamSecondsSinceAppActivity(int32_t state,uint32_t type) {
    (void)state;
    // Scoped AgePad compatibility policy: foreground app counts as use. This
    // is not a system-wide or per-event-type keyboard/mouse idle measurement.
    if (type!=UINT32_MAX || !atomic_load(&TFMSteamPresenceKnown))
        TFMAbortUnimplementedBoundary("SteamCoreGraphics","CGEventSourceSecondsSinceLastEventType: unsupported event type or unknown app activity");
    return TFMSteamOwnAppIsActive() ? 0 : MAX(0,NSProcessInfo.processInfo.systemUptime-atomic_load(&TFMSteamInactiveSince));
}
