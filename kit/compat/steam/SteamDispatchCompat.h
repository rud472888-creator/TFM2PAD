#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

// Exact pinned native completion-port read/write sources monitor an owned
// F_DUPFD_CLOEXEC descriptor. The original descriptor/context/callback remain
// native; the lease closes only after the genuine cancellation callback.
// dispatch_source_get_handle therefore exposes the lease on this narrow path.
// The audited client callbacks use context, not source_get_handle. Other callers
// and source types pass through unchanged. Keep this image loaded for lifetime.
NSDictionary *TFMSteamDispatchCompatStatus(void);

#ifdef TFM_STEAM_DISPATCH_TESTING
// Host tests only, absent from production exports; no vendor code is executed.
dispatch_source_t TFMSteamDispatchTestCreate(dispatch_source_type_t type,int descriptor,
    dispatch_queue_t queue) __attribute__((ns_returns_retained));
dispatch_source_t TFMSteamDispatchTestCreateFailure(int descriptor) __attribute__((ns_returns_retained));
dispatch_source_t TFMSteamDispatchTestRegistrationFailure(int descriptor,dispatch_queue_t queue) __attribute__((ns_returns_retained));
void TFMSteamDispatchTestSetCancel(dispatch_source_t source,dispatch_function_t function);
#endif
