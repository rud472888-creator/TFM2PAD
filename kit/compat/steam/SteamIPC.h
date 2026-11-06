#import <Foundation/Foundation.h>

// Compile SteamIPC.m ONCE as @rpath/TFMSteamIPC.dylib. Both the SDK's
// libSystem boundary and Steam's helper/client libSystem boundary must reexport
// that SAME image. Never compile independent copies into those boundaries.
// Keep it, the genuine helper and client loaded for process lifetime.
// The pinned desktop helper's own process-wide SIGTERM registration is rejected
// with SIG_ERR/ENOTSUP in its exact call/thread scope. Host signal disposition
// and every other signal request retain native semantics. No vendor code edit.
//
// Explicit --tfm-steam-sdk-probe + --tfm-start-steam-engine, background serial
// queue, already guarded real engine/global user and RunFrame pump required.
// This is a separate no-login SDK diagnostic: no game or authentication call.
// Caller must externally terminate the app if a vendor call stalls (30s bound).
// Reads only bundled owned images and bundled SteamIPCProfile.json. The profile
// carries the LC_MAIN observation from the original pinned helper; adaptation
// removes LC_MAIN, so no arbitrary entry-point discovery from machine code.
NSDictionary *TFMSteamIPCProbe(void *validatedClientImage);

// Alternate --tfm-steam-login + --tfm-steam-sdk-probe isolated mode. Call ONLY
// after fresh QR approval and genuine native engine BLoggedOn. Rechecks the
// pinned user's vtable/BLoggedOn code and its actual current return value before
// starting helper or SDK; no cached boolean, token persistence or fake login.
// cancelled is a host-owned read-only flag callback, checked before helper and
// SDK work. It cannot interrupt a vendor call already in progress.
NSDictionary *TFMSteamIPCProbeAfterLogon(void *validatedClientImage,void *validatedUserInterface,
    BOOL (*cancelled)(void));

// Explicit --tfm-play-with-steam only. Rechecks genuine guarded engine logon,
// prepares owned helper+actual app-local service/registration, and validates
// TFMOriginalSteamAPI.dylib imports/code without invoking SDK initialization.
// Root must forward the game's exact original Init call after this succeeds.
// Requires process cwd already fixed at the real Documents/GameRuntime.
NSDictionary *TFMSteamIPCPrepareForGame(void *validatedClientImage,void *validatedUserInterface,
    BOOL (*cancelled)(void));

// Operational counters/booleans only. No paths, identities, ports or tokens.
NSDictionary *TFMSteamIPCStatus(void);
