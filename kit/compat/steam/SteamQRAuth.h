#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

// UI callbacks are dispatched to main. A nil image clears the expired/completed
// QR. No URL, client/request ID, account name or token is delivered to the UI.
typedef void (^TFMSteamQRCodeHandler)(UIImage * _Nullable qrImage);
typedef void (^TFMSteamAuthStatusHandler)(NSString *phase);

// Internal engine integration only. This HTTPS module never persists secrets.
// Never log or put these arguments in telemetry, environment or ordinary files.
// The combined-play host may retain them privately and commit only to its
// app-private device-only Keychain after native BLoggedOn and identity equality.
// Return YES only after genuine guarded engine methods consumed the token,
// not as a login or successful-persistence assertion.
typedef BOOL (^TFMSteamFreshTokenConsumer)(NSString *refreshToken,NSString *accountName,uint64_t steamID);

// One fresh QR session per process, blocking on a background queue, bounded by
// timeout (at most240s). No password flow, existing token/account access,
// Keychain, cookies or credential store. Returns sanitized telemetry only.
NSDictionary *TFMSteamQRAuthenticate(NSTimeInterval timeout,TFMSteamQRCodeHandler onQRCode,
    TFMSteamAuthStatusHandler _Nullable onStatus,TFMSteamFreshTokenConsumer consumeFreshToken);
void TFMSteamCancelQRAuthentication(void);
BOOL TFMSteamQRAuthenticationCancelled(void);
NS_ASSUME_NONNULL_END
