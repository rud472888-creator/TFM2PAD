#import <Foundation/Foundation.h>
#import "../compat/steam/SteamQRAuth.h"

// Main-thread setup before the original game's main. No engine/auth calls here.
void TFMSetSteamGameUIHandlers(TFMSteamQRCodeHandler qr,TFMSteamAuthStatusHandler status);
// Called after the original game image is loaded, its UIKit host is set, and
// GameRuntime cwd is prepared. The natural SDK Init call starts authentication.
BOOL TFMInstallSteamGameCoordinator(void);
