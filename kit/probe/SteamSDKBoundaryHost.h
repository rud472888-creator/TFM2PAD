#import <Foundation/Foundation.h>

// Main thread, before loading the game or either original SDK name.
BOOL TFMPrepareSteamSDKBoundary(void);
// Read-only adapter observations; does not invoke any Steam interface.
NSDictionary *TFMSteamSDKBoundaryObservation(void);
