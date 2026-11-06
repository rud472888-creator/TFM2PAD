#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Internal secret-bearing value. Never put this object or its properties into
// telemetry, UI, process environment, files or arbitrary collection dumps.
@interface TFMSteamCredentialRecord : NSObject
@property(nonatomic,readonly,copy) NSString *refreshToken;
@property(nonatomic,readonly,copy) NSString *accountName;
@property(nonatomic,readonly) uint64_t steamID;
@end

// Validation checks bounds and token-subject routing only. It does NOT verify
// a JWT signature, token validity, login, ownership or entitlement.
TFMSteamCredentialRecord * _Nullable TFMSteamCredentialCreate(NSString *refreshToken,
    NSString *accountName,uint64_t steamID,NSDictionary * _Nullable * _Nullable diagnostic);
// Exactly one fixed app-private, non-synchronizing, device-only Keychain item.
// Caller uses a background queue. Diagnostics contain no account/token values.
TFMSteamCredentialRecord * _Nullable TFMSteamCredentialLoad(NSDictionary * _Nullable * _Nullable diagnostic);
BOOL TFMSteamCredentialSave(TFMSteamCredentialRecord *credential,NSDictionary * _Nullable * _Nullable diagnostic);

// Nonsecret app-owned next-launch policy. A failed/malformed read must prevent
// saved-token restoration. A request never changes the live native session.
NSDictionary *TFMSteamFreshLoginPolicy(void);
// UI recovery: request fresh QR next launch, optionally forget only our saved
// item, then let the host explicitly end/relaunch the process. No native LogOff,
// global token revocation, vendor-cache deletion or process exit occurs here.
NSDictionary *TFMSteamRequestFreshLoginOnNextLaunch(BOOL forgetSavedCredential);
NS_ASSUME_NONNULL_END
