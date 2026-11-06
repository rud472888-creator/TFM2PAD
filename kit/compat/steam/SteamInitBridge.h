#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Original Steam SDK ABI. errorMessage, when nonnull, points to SteamErrMsg's
// 1024-byte buffer. The versions string and error pointer remain caller-owned.
typedef int (*TFMSteamOriginalInitFn)(const char *versions,char *errorMessage);
typedef int (*TFMSteamInitCoordinatorFn)(const char *versions,char *errorMessage,
    TFMSteamOriginalInitFn originalInit,void *context);

// Register once, on main, before any SDK initialization reaches this bridge.
// The callback/context must remain alive for the process lifetime. Registration
// never starts an engine, authentication, SDK initialization or a game.
//
// Only explicit --tfm-play-with-steam uses the callback. It runs on the game's
// main-thread init call. Its originalInit argument is a guarded one-call thunk:
// call synchronously on that same thread with the exact versions/error pointers
// received by the coordinator. Preserve the vendor error buffer after return.
// If the SDK is called, its actual integer result is returned unchanged even
// if the coordinator returns something else. If preparation fails before the
// SDK call, return failure; the bridge returns a labeled adapter failure (1).
// Concurrent, recursive and repeated combined attempts require a fresh process.
FOUNDATION_EXPORT BOOL TFMSteamConfigureInitCoordinator(TFMSteamInitCoordinatorFn coordinator,void *context);

// The only overridden SDK symbol. Every other SDK export must be supplied by
// the builder's reexport of @rpath/TFMOriginalSteamAPI.dylib.
FOUNDATION_EXPORT int SteamInternal_SteamAPI_Init(const char *versions,char *errorMessage);

#ifdef __cplusplus
}
#endif
