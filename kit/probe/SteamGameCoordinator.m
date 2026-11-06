#import "SteamGameCoordinator.h"
#import "SteamSDKBoundaryHost.h"
#import "../compat/steam/SteamEngineProbe.h"
#import "../compat/steam/SteamInitBridge.h"
#import "../compat/steam/SteamLaunchPolicy.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static TFMSteamQRCodeHandler QRHandler;
static TFMSteamAuthStatusHandler StatusHandler;
static NSMutableDictionary *Progress;
static void *BridgeImage;
static void *ClientImage;
static BOOL Configured;

static void Record(NSString *stage,NSDictionary *fields) {
    if (!Progress) Progress=[NSMutableDictionary dictionary];
    [Progress addEntriesFromDictionary:fields ?: @{}];
    Progress[@"stage"]=stage;
    Progress[@"pid"]=@(getpid());
    Progress[@"timestamp_unix"]=@(NSDate.date.timeIntervalSince1970);
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *json=[NSJSONSerialization dataWithJSONObject:Progress options:NSJSONWritingPrettyPrinted error:NULL];
    [json writeToURL:[documents URLByAppendingPathComponent:@"steam-game-session.json"] atomically:YES];
}
static void Phase(NSString *phase) { if (StatusHandler) StatusHandler(phase); }
static int StartupFailure(char *error,const char *message,NSString *code) {
    if (error) strlcpy(error,message,1024); // Valve SteamErrMsg ABI.
    Record(@"startup_failed",@{@"status":@"failed",@"failure_code":code,@"original_sdk_called":@NO});
    Phase(@"game_steam_sdk_failed");
    return 1; // Explicit bridge failure, never reported as a vendor result.
}

@interface TFMGameSessionWork : NSObject
@property(nonatomic,strong) NSDictionary *result;
@property(nonatomic) BOOL done;
@end
@implementation TFMGameSessionWork @end

static int CoordinateInit(const char *versions,char *error,TFMSteamOriginalInitFn original,void *context) {
    (void)context;
    if (!NSThread.isMainThread) {
        if (error) strlcpy(error,"Steam game startup requires the game's main thread.",1024);
        return 1;
    }
    if (!Configured || !original || !QRHandler || !StatusHandler)
        return StartupFailure(error,"Steam game startup coordinator is unavailable.",@"coordinator_precondition_failed");
    Record(@"preparing_real_engine",@{@"status":@"starting",@"original_sdk_called":@NO,
        @"original_arguments_forwarded_unchanged":@NO,@"identity_or_tokens_recorded":@NO});
    Phase(@"auth_preconditions");
    NSURL *client=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"steamclient.dylib"];
    ClientImage=dlopen(client.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    if (!ClientImage) return StartupFailure(error,"The bundled Steam client could not be loaded.",@"client_load_failed");
    TFMGameSessionWork *work=[TFMGameSessionWork new];
    dispatch_queue_t queue=dispatch_queue_create("org.tfm2pad.steam-game-session",DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue,^{
        @autoreleasepool {
            NSDictionary *result=nil;
            @try { result=TFMSteamStartGameSession(ClientImage,QRHandler,StatusHandler); }
            @catch (__unused NSException *exception) {
                result=@{@"status":@"failed",@"failure_code":@"game_session_objective_c_exception"};
            }
            @synchronized(work) { work.result=result ?: @{@"status":@"failed"};work.done=YES; }
            CFRunLoopWakeUp(CFRunLoopGetMain());
        }
    });
    // QR 210s + native logon 60s + license readiness 30s, with setup margin.
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+360;
    NSTimeInterval cancelDeadline=0;
    NSDictionary *result=nil;
    for (;;) {
        @synchronized(work) { if (work.done) { result=work.result;break; } }
        NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        if (TFMSteamQRAuthenticationCancelled() && !cancelDeadline) cancelDeadline=now+5;
        if (now>=deadline || (cancelDeadline && now>=cancelDeadline)) {
            TFMSteamCancelQRAuthentication();
            Record(@"unsettled_vendor_worker_process_exit",@{@"status":@"failed",
                @"failure_code":@"vendor_worker_did_not_settle_within_host_bound",
                @"original_sdk_called":@NO,@"exit_code":@75});
            // Do not let the game run while an uninterruptible vendor call is
            // still changing process-wide Steam state. No thread cancellation.
            fflush(NULL);_exit(75);
        }
        // The original main was entered from an NSTimer, outside a main GCD
        // block. This preserves UIKit input and the engine's main-queue work.
        @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.025,true); }
    }
    Record(@"engine_session_returned",@{@"engine_session_status":result[@"status"] ?: @"unknown"});
    NSDictionary *snapshot=TFMSteamGameSessionSnapshot();
    BOOL ready=[result[@"status"] isEqual:@"game_steam_session_ready_for_original_sdk"] &&
        [result[@"ready"] boolValue] && [snapshot[@"ready"] boolValue];
    if ((!ready || TFMSteamQRAuthenticationCancelled()) &&
        ([result[@"factory_called"] boolValue] || [result[@"process_restart_required_after_failure"] boolValue])) {
        Record(@"failed_native_session_requires_process_exit",@{@"status":@"failed",
            @"failure_code":result[@"failure_code"] ?: @"session_not_ready_after_native_engine_started",
            @"original_sdk_called":@NO,@"exit_code":@75});
        // The startup worker has returned, but native background threads may
        // still exist. Keep the original SDK/game call suspended while UIKit
        // presents recovery; only a full process exit can start another session.
        if (!TFMSteamQRAuthenticationCancelled()) {
            Record(@"failed_session_waiting_for_user_restart",@{@"status":@"failed",
                @"original_sdk_called":@NO,@"same_process_retry_allowed":@NO});
            Phase(@"game_steam_restart_required");
            while (!TFMSteamQRAuthenticationCancelled()) {
                @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.025,true); }
            }
        }
        fflush(NULL);_exit(75);
    }
    if (TFMSteamQRAuthenticationCancelled())
        return StartupFailure(error,"Steam login was cancelled.",@"cancelled_before_original_sdk");
    if (!ready)
        return StartupFailure(error,"Steam session preparation did not complete.",result[@"failure_code"] ?: @"engine_session_not_ready");
    Record(@"original_sdk_call_pending",@{@"original_sdk_called":@YES,
        @"original_arguments_forwarded_unchanged":@YES,@"engine_session_retained":@YES});
    Phase(@"checking_original_steam_sdk");
    int nativeResult=1;
    @try { nativeResult=original(versions,error); }
    @catch (__unused NSException *exception) {
        Record(@"original_sdk_exception",@{@"status":@"failed",@"original_sdk_called":@YES,
            @"original_sdk_result_observed":@NO});
        Phase(@"game_steam_sdk_failed");return 1;
    }
    Record(@"original_sdk_returned",@{@"status":nativeResult==0?@"original_sdk_initialized_in_game":@"original_sdk_failed_in_game",
        @"sdk_client_boundary":TFMSteamSDKBoundaryObservation(),
        @"original_sdk_result":@(nativeResult),@"original_sdk_result_forwarded_unchanged":@YES,
        @"ownership_or_cloud_success_claimed":@NO});
    Phase(nativeResult==0?@"game_steam_sdk_connected":@"game_steam_sdk_failed");
    return nativeResult;
}

void TFMSetSteamGameUIHandlers(TFMSteamQRCodeHandler qr,TFMSteamAuthStatusHandler status) {
    if (!NSThread.isMainThread || Configured) return;
    QRHandler=[qr copy];StatusHandler=[status copy];
}
BOOL TFMInstallSteamGameCoordinator(void) {
    if (!NSThread.isMainThread || Configured || !QRHandler || !StatusHandler ||
        !TFMSteamCombinedLaunchRequested()) return NO;
    NSURL *bridge=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"libsteam_api.dylib"];
    BridgeImage=dlopen(bridge.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    BOOL (*configure)(TFMSteamInitCoordinatorFn,void *)=BridgeImage?dlsym(BridgeImage,"TFMSteamConfigureInitCoordinator"):NULL;
    Dl_info image={0};
    if (!configure || !dladdr((void *)configure,&image) || !image.dli_fname ||
        ![@(image.dli_fname).lastPathComponent isEqual:@"libsteam_api.dylib"]) {
        Record(@"configuration_failed",@{@"failure_code":@"concrete_init_bridge_unavailable"});
        Phase(@"game_steam_sdk_failed");return NO;
    }
    Configured=configure(CoordinateInit,NULL);
    Record(@"coordinator_configured",@{@"configured":@(Configured),@"original_sdk_called":@NO});
    if (!Configured) Phase(@"game_steam_sdk_failed");
    return Configured;
}
