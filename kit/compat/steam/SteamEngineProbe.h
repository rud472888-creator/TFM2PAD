#import <Foundation/Foundation.h>
#import "SteamQRAuth.h"

// Explicit one-shot diagnostic, not a game/SteamAPI/authentication route.
// Call on a background serial queue with the main queue responsive. The handle
// must be the already-validated genuine client image and must remain loaded.
// TFMAppKit host window must be set. This isolated mode may create the base
// NSApplication singleton if Winit has not registered yet; restart before game.
// This creates fresh Documents/SteamEngine storage and changes cwd plus two
// Steam-specific path variables for this isolated process lifetime; HOME stays
// unchanged. Cache paths are configured, not a filesystem confinement proof.
// Vendor calls cannot safely be interrupted: root must bound/terminate the app
// externally if progress stops. Restart the process before testing game mode.
// No LogOn/LogOff/token/ownership/game entrypoint is called. The additional
// explicit --tfm-steam-sdk-probe flag invokes the shared SteamIPC dylib after
// the real engine/global-user/pump, for a separate genuine SDK-init diagnostic.
// That mode requires the single shared IPC reexport and SteamIPCProfile.json;
// see SteamIPC.h. Without the flag no SDK initialization is called.
NSDictionary *TFMSteamEngineProbe(void *validatedClientImage);

// Separate explicit --tfm-steam-login mode; never combine with --tfm-run-main.
// Fresh real QR approval only; transient token passed to guarded native engine.
// UI callbacks run on main. Success requires actual BLoggedOn, not HTTPS approval.
// QR210s + engine60s + optional native subscription wait<=30s. Pump bound330s;
// caller must impose an outer app bound of360s (foreign calls can stall).
// Optional --tfm-steam-sdk-probe additionally invokes the original helper/SDK
// ONLY after actual guarded native BLoggedOn and native BIsSubscribedApp(3009300)
// observed true. BLoggedOn is rechecked inside shared SteamIPC.
// No prior token is loaded; no helper/SDK attempt follows timeout/cancellation.
// Additional UI phases: waiting_for_native_subscription, checking_original_steam_sdk.
// Subscription timeout records the actual last bool and prevents helper/SDK
// calls; a false observation is not proof of permanent lack of entitlement.
// Terminal successful login
// stays steam_engine_logged_on, with the actual SDK result in the report.
NSDictionary *TFMSteamEngineQRLogin(void *validatedClientImage,TFMSteamQRCodeHandler onQRCode,
    TFMSteamAuthStatusHandler onStatus);

// --tfm-play-with-steam only, background serial queue. Original main must
// already have created its actual WinitApplication singleton before its natural
// SDK Init reaches the root wrapper. Require host ready, not launched/running,
// and cwd already Documents/GameRuntime. Never creates/reset/retypes NSApp.
// Only effective combined play may restore this app's private Keychain record;
// a missing record uses fresh QR. Read failures are visible and never silently
// retry/reset the native engine. --tfm-steam-fresh-login or the app's persisted
// next-launch policy bypasses saved-token reads. Recovery requires a fresh
// process; TFMSteamRequestFreshLoginOnNextLaunch never ends a live session.
// A future QR-issued record is saved only after native BLoggedOn and genuine
// GetSteamID equality; save failure does not invalidate successful native login.
// Genuine native BLoggedOn and native BIsSubscribedApp(3009300),
// then genuine helper registration only;
// SDK Init is NOT called. Ready status: game_steam_session_ready_for_original_sdk.
// Engine pump and native image/object references survive for process lifetime.
// Root keeps main UI responsive and externally bounds initial preparation360s.
NSDictionary *TFMSteamStartGameSession(void *validatedClientImage,TFMSteamQRCodeHandler onQRCode,
    TFMSteamAuthStatusHandler onStatus);

// Recorded observations only, safe from main. No foreign calls, IDs or tokens.
// ready is additionally false if the retained pump stopped or auth was cancelled.
NSDictionary *TFMSteamGameSessionSnapshot(void);
