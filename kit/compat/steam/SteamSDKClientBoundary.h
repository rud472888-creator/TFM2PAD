#pragma once
#import <Foundation/Foundation.h>

typedef void *(*TFMSteamNativeDlsym)(void *handle,const char *name);

// The host must call this on main BEFORE loading the owned SDK. Pass the host's
// own System-bound dlsym pointer, not a lookup through this provider. It is
// checked against the Apple loader and concrete libSystem export. Repeating
// the same configuration succeeds; changing the pointer is rejected.
FOUNDATION_EXPORT BOOL TFMSteamSDKClientBoundaryConfigure(TFMSteamNativeDlsym nativeDlsym);

// Operational counts/booleans only: never identities, tokens or handle values.
FOUNDATION_EXPORT NSDictionary *TFMSteamSDKClientBoundarySnapshot(void);

// Build this SDK-only provider as @rpath/TFMSteamSDKClientBoundary.dylib,
// reexporting the existing @rpath/TFMlibSystem.dylib. Redirect ONLY the owned
// SDK's libSystem dependency. The client/engine must retain their providers.
// The sole adapted behavior requires explicit --tfm-sdk-client-order-fix.
