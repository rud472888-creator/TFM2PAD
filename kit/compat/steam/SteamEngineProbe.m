// ABI/interface discovery selectively adapted from AgePad SteamEngineHost.c.
// Copyright (c) 2026 Chris Sotraidis. MIT permission notice: NOTICE.md.
// No upstream login, token, ownership, game-attach or unbounded pump is vendored.
#import "SteamEngineProbe.h"
#import "SteamCredentialStore.h"
#import "SteamLaunchPolicy.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/loader.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>

static atomic_bool ProbeAttempted;
static const uintptr_t EngineVTable=0x1753a20,EngineRTTI=0x1753d30;
static const uintptr_t UserVTable=0x173fe80,UserRTTI=0x17406c0;
typedef struct { const char *name; int slot; uintptr_t offset; const char *sha256; } FunctionGuard;
static const FunctionGuard FactoryGuard={"CreateInterface",-1,0x10857e0,"4688a93410b24036655a8e2ed0f53cce898e7e29c1af0b06361914b5cd6264c8"};
static const FunctionGuard EngineGuards[]={
    {"CreateGlobalUser",2,0xa01c9c,"b9d07f8484936765c5c3dca947837a237676d8f4e2c67b45c01806b76fa3831e"},
    {"GetIClientUser",8,0xa02be8,"8a20a4dd9f0c88e98f8979f8b809c682a969be65207f5aafa559ef03df0bc497"},
    {"RunFrame",19,0xa05bf8,"2531223fd02973004f9a167bf2954230a0ef83da5580aa385e3d74394a3aefa6"}
};
static const FunctionGuard QueryGuards[]={
    {"BLoggedOn",4,0x891370,"f0a0ae4c5be3753eb2425c54775122d3e40dffa385792449e8a015647e399a0a"},
    {"GetLogonState",5,0x8914dc,"dae1b6ca117afe3623ad958efb34aee4bed540be131bdaa2a608f3ee248ef924"},
    {"BConnected",6,0x891648,"75b9af72b3ffa9b745a9dd212b25619b0e60e3a09a0fa7fe70b065913cca777b"},
    {"GetSteamID",10,0x891bf8,"bcd29369fbd20f8271f762da82219f2c32b4c7e926133eaa70371dfc0414140a"}
};

static const FunctionGuard LoginGuards[]={
    {"LogOn",1,0x890f10,"f9512095a23a6a71f55c3ce6a89f7300f143f45f8fc873b09e092d6e3a286533"},
    {"SetLoginToken",56,0x896610,"eafdeeb110f810ff7ed8bdbbc90795ca08bca59fc4aa432b289060cb8af72897"}
};
// Exact owned client: the IClientUserMap proxy serializes one uint32 app ID
// and deserializes one bool. It is not an IClientApps or public SDK object.
static const FunctionGuard SubscriptionGuard={"BIsSubscribedApp",181,0x8a2a10,"03bdab7e152c8339c437289120df01316e2c5b7dfc424332ca1b5028c6eef617"};

static BOOL ReadMemory(uintptr_t address,void *destination,size_t size) {
    if (!address || !destination || !size) return NO;
    vm_size_t copied=0;
    return vm_read_overwrite(mach_task_self(),(vm_address_t)address,(vm_size_t)size,
        (vm_address_t)(uintptr_t)destination,&copied)==KERN_SUCCESS && copied==size;
}
static BOOL ImageOwns(uintptr_t address,uintptr_t base) {
    Dl_info info={0};
    return address && dladdr((void *)address,&info) && (uintptr_t)info.dli_fbase==base;
}
static BOOL Executable(uintptr_t address) {
    vm_address_t start=address; vm_size_t size=0;
    vm_region_basic_info_data_64_t info={0}; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t result=vm_region_64(mach_task_self(),&start,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if (MACH_PORT_VALID(object)) mach_port_deallocate(mach_task_self(),object);
    return result==KERN_SUCCESS && address>=start && address<start+size && (info.protection&VM_PROT_READ) && (info.protection&VM_PROT_EXECUTE);
}
static BOOL ReadString(uintptr_t address,char *buffer,size_t capacity) {
    for (size_t i=0;i<capacity;i++) {
        if (!ReadMemory(address+i,buffer+i,1)) return NO;
        if (!buffer[i]) return YES;
    }
    return NO;
}
static BOOL PinnedImageUUID(uintptr_t base) {
    static const uint8_t expected[]={0x04,0x72,0x94,0x90,0x26,0x58,0x33,0x63,0xbd,0x8d,0x74,0x64,0x21,0xf1,0x04,0x35};
    struct mach_header_64 header;
    if (!ReadMemory(base,&header,sizeof header) || header.magic!=MH_MAGIC_64 || header.cputype!=CPU_TYPE_ARM64 || header.filetype!=MH_DYLIB || header.ncmds>1024 || header.sizeofcmds>1024*1024) return NO;
    uintptr_t cursor=base+sizeof header,end=cursor+header.sizeofcmds;
    for (uint32_t i=0;i<header.ncmds;i++) {
        struct load_command command;
        if (!ReadMemory(cursor,&command,sizeof command) || command.cmdsize<sizeof command || cursor+command.cmdsize>end) return NO;
        if (command.cmd==LC_UUID) {
            struct uuid_command uuid;
            return command.cmdsize>=sizeof uuid && ReadMemory(cursor,&uuid,sizeof uuid) && !memcmp(uuid.uuid,expected,sizeof expected);
        }
        cursor+=command.cmdsize;
    }
    return NO;
}
static BOOL GuardFunction(uintptr_t function,uintptr_t base,const FunctionGuard *guard) {
    if (function!=base+guard->offset || !ImageOwns(function,base) || !Executable(function)) return NO;
    uint8_t bytes[64],hash[CC_SHA256_DIGEST_LENGTH]; char hex[CC_SHA256_DIGEST_LENGTH*2+1];
    if (!ReadMemory(function,bytes,sizeof bytes)) return NO;
    CC_SHA256(bytes,(CC_LONG)sizeof bytes,hash);
    for (size_t i=0;i<sizeof hash;i++) snprintf(hex+i*2,3,"%02x",hash[i]);
    return !strcmp(hex,guard->sha256);
}
static BOOL GuardObject(void *object,uintptr_t base,uintptr_t expectedTable,uintptr_t expectedRTTI,const char *expectedName,uintptr_t *tableOut) {
    uintptr_t table=0,rtti=0,name=0; int64_t top=-1; char text[128]={0};
    if (!ReadMemory((uintptr_t)object,&table,sizeof table) || table!=base+expectedTable || !ImageOwns(table,base) ||
        !ReadMemory(table-2*sizeof(uintptr_t),&top,sizeof top) || top!=0 ||
        !ReadMemory(table-sizeof(uintptr_t),&rtti,sizeof rtti) || rtti!=base+expectedRTTI ||
        !ReadMemory(rtti+sizeof(uintptr_t),&name,sizeof name) || !ImageOwns(name,base) ||
        !ReadString(name,text,sizeof text) || strcmp(text,expectedName)) return NO;
    *tableOut=table; return YES;
}
static uintptr_t Slot(uintptr_t table,int slot) {
    uintptr_t function=0;
    return slot>=0 && ReadMemory(table+(uintptr_t)slot*sizeof(uintptr_t),&function,sizeof function) ? function : 0;
}
static BOOL ProxyName(uintptr_t function,uintptr_t base,char *name,size_t capacity) {
    uint32_t code[256];
    if (!ImageOwns(function,base) || !Executable(function) || !ReadMemory(function,code,sizeof code)) return NO;
    uintptr_t page=0;
    for (int i=0;i<256;i++) {
        uint32_t instruction=code[i];
        if (instruction==0xd65f03c0) return NO;
        if ((instruction&0x9f00001f)==0x90000004) {
            int64_t immediate=(int64_t)((((instruction>>5)&0x7ffff)<<2)|((instruction>>29)&3));
            if (immediate&(1<<20)) immediate-=1<<21;
            page=(uintptr_t)((intptr_t)((function+(uintptr_t)i*4)&~(uintptr_t)0xfff)+immediate*4096);
        } else if ((instruction&0xffc003ff)==0x91000084 && page) {
            uintptr_t string=page+((instruction>>10)&0xfff);
            return ImageOwns(string,base) && ReadString(string,name,capacity);
        }
    }
    return NO;
}
static int FindQuery(uintptr_t table,uintptr_t base,const char *wanted) {
    for (int slot=0;slot<400;slot++) {
        uintptr_t function=Slot(table,slot); char name[128]={0};
        if (!ImageOwns(function,base) || !Executable(function)) break;
        if (ProxyName(function,base,name,sizeof name) && !strcmp(name,wanted)) return slot;
    }
    return -1;
}

static BOOL Save(NSMutableDictionary *report,NSURL *url,NSString *stage,NSString *status) {
    @synchronized(report) {
        if (stage) report[@"stage"]=stage;
        if (status) report[@"status"]=status;
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        BOOL saved=json && [json writeToURL:url options:NSDataWritingAtomic error:NULL];
        if (stage) { fprintf(stderr,"TFM_STEAM_ENGINE stage=%s status=%s\n",stage.UTF8String,[report[@"status"] UTF8String]); fflush(stderr); }
        return saved;
    }
}
static NSDictionary *Fail(NSMutableDictionary *report,NSURL *url,NSString *code) {
    @synchronized(report) { report[@"failure_code"]=code; }
    Save(report,url,nil,@"failed");
    @synchronized(report) {return [report copy];}
}

@interface TFMSteamEnginePump : NSObject
@property(nonatomic) void *engine;
@property(nonatomic) void *runFrame;
@property(nonatomic,strong) NSMutableDictionary *report;
@property(nonatomic,strong) NSURL *progressURL;
@property(atomic) BOOL stop;
@property(atomic) NSUInteger ticks;
@property(atomic) BOOL progressFailure;
@property(atomic) BOOL diagnosticWriteFailure;
@property(nonatomic) NSTimeInterval maximumSeconds;
@property(atomic) BOOL processLifetime;
@property(nonatomic) BOOL gameSession;
@property(nonatomic) void *clientImage;
@property(nonatomic) void *user;
@property(nonatomic) void *appKitImage;
@property(nonatomic) void *ipcImage;
@end
@implementation TFMSteamEnginePump @end
static TFMSteamEnginePump *RetainedGamePump;
static NSMutableDictionary *GameSessionReport;
static void *Pump(void *argument) {
    @autoreleasepool {
        TFMSteamEnginePump *pump=(__bridge_transfer TFMSteamEnginePump *)argument;
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+pump.maximumSeconds;
        while (!pump.stop && (pump.processLifetime || NSProcessInfo.processInfo.systemUptime<deadline)) {
            @autoreleasepool {
                if (pump.gameSession && TFMSteamQRAuthenticationCancelled()) break;
                BOOL persistent=pump.processLifetime;
                BOOL persist=!persistent || !(pump.ticks%100);
                @synchronized(pump.report) { pump.report[@"pump_call_pending"]=@YES; }
                if (persist && !Save(pump.report,pump.progressURL,nil,nil)) {
                    if (!persistent) {pump.progressFailure=YES;break;}
                    pump.diagnosticWriteFailure=YES;
                    @synchronized(pump.report) {pump.report[@"diagnostic_write_failed_after_ready"]=@YES;}
                }
                ((void(*)(void *))pump.runFrame)(pump.engine);
                pump.ticks++;
                @synchronized(pump.report) {
                    pump.report[@"pump_call_pending"]=@NO;pump.report[@"pump_ticks"]=@(pump.ticks);
                    pump.report[@"last_RunFrame_return_uptime"]=@(NSProcessInfo.processInfo.systemUptime);
                }
                if (persist && !Save(pump.report,pump.progressURL,nil,nil)) {
                    if (!persistent) {pump.progressFailure=YES;break;}
                    pump.diagnosticWriteFailure=YES;
                    @synchronized(pump.report) {pump.report[@"diagnostic_write_failed_after_ready"]=@YES;}
                }
                usleep(10000);
            }
        }
        @synchronized(pump.report) {
            pump.report[@"pump_thread_finished"]=@YES;
            if (pump.gameSession && pump.processLifetime) {
                pump.report[@"status"]=TFMSteamQRAuthenticationCancelled()?@"cancelled":@"failed";
                pump.report[@"failure_code"]=TFMSteamQRAuthenticationCancelled()?@"game_session_cancelled_pump_stopped":@"game_session_pump_stopped";
            }
        }
        if (!Save(pump.report,pump.progressURL,nil,nil)) {
            if (pump.processLifetime) pump.diagnosticWriteFailure=YES;else pump.progressFailure=YES;
        }
    }
    return NULL;
}
NSDictionary *TFMSteamGameSessionSnapshot(void) {
    @synchronized([TFMSteamEnginePump class]) {
        if (!GameSessionReport) return @{@"status":@"not_started",@"ready":@NO,@"snapshot_is_recorded_observation":@YES};
        @synchronized(GameSessionReport) {
            NSMutableDictionary *result=[GameSessionReport mutableCopy];
            NSTimeInterval lastReturn=[result[@"last_RunFrame_return_uptime"] doubleValue];
            BOOL alive=RetainedGamePump && !RetainedGamePump.stop && !RetainedGamePump.progressFailure && ![result[@"pump_thread_finished"] boolValue] &&
                lastReturn>0 && NSProcessInfo.processInfo.systemUptime-lastReturn<=2;
            result[@"pump_alive"]=@(alive);
            BOOL subscriptionReady=[result[@"native_subscription_readiness"][@"ready_for_helper_or_sdk"] boolValue];
            result[@"ready"]=@([result[@"status"] isEqual:@"game_steam_session_ready_for_original_sdk"] && alive && subscriptionReady && RetainedGamePump.processLifetime && !TFMSteamQRAuthenticationCancelled());
            if ([result[@"status"] isEqual:@"game_steam_session_ready_for_original_sdk"] && ![result[@"ready"] boolValue]) result[@"status"]=@"game_session_no_longer_ready";
            result[@"snapshot_is_recorded_observation"]=@YES;return result;
        }
    }
}
static BOOL GameRuntimeCurrentDirectory(NSURL *documents) {
    NSURL *runtime=[documents URLByAppendingPathComponent:@"GameRuntime" isDirectory:YES];
    NSString *expectedPath=[documents.URLByResolvingSymlinksInPath.path stringByAppendingPathComponent:@"GameRuntime"];
    if (![runtime.URLByResolvingSymlinksInPath.path isEqual:expectedPath]) return NO;
    char current[PATH_MAX],expected[PATH_MAX];
    return realpath(".",current) && realpath(runtime.fileSystemRepresentation,expected) && !strcmp(current,expected);
}

static NSDictionary *StateSample(NSMutableDictionary *report,NSURL *progress,void *user,const uintptr_t queries[4],NSTimeInterval started) {
    NSMutableDictionary *sample=[NSMutableDictionary dictionary];
    if (!Save(report,progress,@"BLoggedOn_pending",@"observing")) return nil;
    sample[@"logged_on"]=@(((bool(*)(void *))queries[0])(user));
    if (!Save(report,progress,@"GetLogonState_pending",@"observing")) return nil;
    sample[@"logon_state"]=@(((int32_t(*)(void *))queries[1])(user));
    if (!Save(report,progress,@"BConnected_pending",@"observing")) return nil;
    sample[@"connected"]=@(((bool(*)(void *))queries[2])(user));
    if (!Save(report,progress,@"GetSteamID_presence_only_pending",@"observing")) return nil;
    uint64_t identity=((uint64_t(*)(void *))queries[3])(user);
    sample[@"steam_identity_present"]=@(identity!=0);
    sample[@"elapsed_seconds"]=@(NSProcessInfo.processInfo.systemUptime-started);
    return sample;
}
static void LoginStatus(TFMSteamAuthStatusHandler callback,NSString *phase) {
    if (callback) dispatch_async(dispatch_get_main_queue(),^{callback(phase);});
}
static NSString *SubscriptionWaitInterruption(NSMutableDictionary *report,TFMSteamEnginePump *pump,NSTimeInterval deadline) {
    if (TFMSteamQRAuthenticationCancelled()) return @"native_subscription_wait_cancelled";
    if (NSProcessInfo.processInfo.systemUptime>=deadline) return @"native_subscription_wait_deadline_reached";
    BOOL finished=NO;@synchronized(report) {finished=[report[@"pump_thread_finished"] boolValue];}
    if (pump.stop || pump.progressFailure || finished) return @"engine_pump_unavailable_during_subscription_wait";
    return nil;
}
static BOOL WaitForNativeSubscription(NSMutableDictionary *report,NSURL *progress,void *user,uintptr_t base,
    uintptr_t loggedOnFunction,uintptr_t subscriptionFunction,TFMSteamEnginePump *pump,TFMSteamAuthStatusHandler onStatus) {
    uintptr_t table=0;
    if (!GuardObject(user,base,UserVTable,UserRTTI,"14IClientUserMap",&table) ||
        Slot(table,SubscriptionGuard.slot)!=subscriptionFunction || !GuardFunction(subscriptionFunction,base,&SubscriptionGuard)) {
        @synchronized(report) {report[@"failure_code"]=@"native_subscription_query_guard_failed";}
        return NO;
    }
    LoginStatus(onStatus,@"waiting_for_native_subscription");
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime,deadline=started+30;
    NSUInteger calls=0;BOOL subscribed=NO;NSString *failure=nil;
    if (!Save(report,progress,@"native_subscription_readiness_pending",@"observing")) {
        @synchronized(report) {report[@"failure_code"]=@"progress_write_failed_before_subscription_query";}
        return NO;
    }
    while (NSProcessInfo.processInfo.systemUptime<deadline) {
        @autoreleasepool {
            failure=SubscriptionWaitInterruption(report,pump,deadline);if (failure) break;
            BOOL loggedOn=((bool(*)(void *))loggedOnFunction)(user);
            @synchronized(report) {report[@"actual_engine_logged_on"]=@(loggedOn);}
            failure=SubscriptionWaitInterruption(report,pump,deadline);if (failure) break;
            if (!loggedOn) {failure=@"engine_logon_lost_during_subscription_wait";break;}
            @synchronized(report) {report[@"ownership_queried"]=@YES;report[@"native_subscription_call_pending"]=@YES;}
            subscribed=((bool(*)(void *,uint32_t))subscriptionFunction)(user,3009300);
            calls++;
            @synchronized(report) {
                report[@"native_subscription_call_pending"]=@NO;
                report[@"native_subscription_readiness"]=@{@"status":subscribed?@"subscribed_observed":@"waiting",
                    @"app_id":@3009300,@"query":@"IClientUserMap_BIsSubscribedApp",@"abi_guards_passed":@YES,
                    @"query_calls":@(calls),@"last_observed_subscribed_app":@(subscribed),
                    @"elapsed_seconds":@(NSProcessInfo.processInfo.systemUptime-started),@"maximum_wait_seconds":@30,
                    @"scope":@"Native subscription observation for this app ID; no latest-build or global ownership conclusion"};
            }
            failure=SubscriptionWaitInterruption(report,pump,deadline);if (failure) break;
            if (subscribed) break;
            if ((calls==1 || !(calls%10)) && !Save(report,progress,nil,nil)) {failure=@"progress_write_failed_during_subscription_wait";break;}
            usleep(100000);
        }
    }
    failure=SubscriptionWaitInterruption(report,pump,deadline) ?: failure;
    if (!subscribed && !failure) failure=@"native_subscription_not_observed_before_deadline";
    @synchronized(report) {
        NSMutableDictionary *observation=[report[@"native_subscription_readiness"] mutableCopy] ?: [NSMutableDictionary dictionary];
        observation[@"status"]=failure ?: @"subscribed_observed";
        observation[@"query_calls"]=@(calls);observation[@"maximum_wait_seconds"]=@30;
        observation[@"elapsed_seconds"]=@(NSProcessInfo.processInfo.systemUptime-started);
        observation[@"ready_for_helper_or_sdk"]=@(subscribed && !failure);
        report[@"native_subscription_readiness"]=observation;
        if (failure) report[@"failure_code"]=failure;
    }
    if (!Save(report,progress,@"native_subscription_readiness_result",@"observing")) {
        @synchronized(report) {report[@"failure_code"]=@"progress_write_failed_at_subscription_result";}
        return NO;
    }
    // Even the diagnostic write may have consumed the remaining deadline.
    // Preserve the native bool while refusing a late/cancelled readiness grant.
    NSString *interruption=SubscriptionWaitInterruption(report,pump,deadline);
    if (interruption) {
        @synchronized(report) {
            NSMutableDictionary *observation=[report[@"native_subscription_readiness"] mutableCopy];
            observation[@"status"]=interruption;observation[@"ready_for_helper_or_sdk"]=@NO;
            observation[@"elapsed_seconds"]=@(NSProcessInfo.processInfo.systemUptime-started);
            report[@"native_subscription_readiness"]=observation;report[@"failure_code"]=interruption;
        }
        Save(report,progress,nil,nil);return NO;
    }
    return subscribed && !failure;
}

static NSDictionary *RunEngine(void *client,BOOL login,BOOL gameSession,TFMSteamQRCodeHandler onQRCode,TFMSteamAuthStatusHandler onStatus) {
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *progress=[documents URLByAppendingPathComponent:gameSession?@"steam-game-session-progress.json":@"steam-engine-progress.json"];
    NSMutableDictionary *report=[@{@"schema_version":@1,@"status":@"starting",@"stage":@"preconditions",
        @"scope":@"One-shot genuine client factory/global-user/bounded frame-pump observation; no login, token, ownership, SDKInit or game calls",
        @"abi_profile":@"steamclient-arm64-c608f74c74f6f90b794e47d51bce5421ef0f3dea0681faa8d10ce155c1a1cd09",
        @"factory_called":@NO,@"global_user_call_made":@NO,@"logon_functions_called":@NO,@"ownership_queried":@NO,
        @"native_subscription_readiness":@{@"status":@"not_run",@"app_id":@3009300,@"query_calls":@0},
        @"account_identity_values_recorded":@NO,@"game_main_called":@NO,@"SteamAPI_Init_called":@NO,
        @"HOME_modified":@NO,@"cache_filesystem_confinement_proven":@NO,@"process_restart_required_after_probe":@YES,
        @"limitations":@[@"Pinned vtable/RTTI/text guards apply only to this exact client version; a Steam update must be re-audited.",
            @"Fresh configured config/log/cwd locations are not proof of every vendor filesystem access.",
            @"Vendor calls cannot safely be interrupted; external app timeout/termination is required if progress stalls.",
            @"The bounded probe does not safely shut down all client-owned internal threads; restart the app before other modes.",
            @"No login function is called, but client initialization may perform network activity."]} mutableCopy];
    report[@"login_requested"]=@(login);
    if (login) {
        report[@"scope"]=@"Isolated fresh QR approval and guarded native-engine login; no existing tokens, ownership, SDKInit or game calls";
        report[@"toolkit_token_persistence"]=@"memory_only_no_keychain";
        report[@"native_client_token_cache_persistence"]=@"not_measured";
        NSMutableArray *limits=[report[@"limitations"] mutableCopy];
        limits[limits.count-1]=@"QR approval is separate from genuine engine BLoggedOn. No game ownership or combined-game readiness is claimed.";
        report[@"limitations"]=limits;
    }
    if (gameSession) {
        @synchronized([TFMSteamEnginePump class]) {
            if (GameSessionReport) return TFMSteamGameSessionSnapshot();
            GameSessionReport=report;
        }
        report[@"scope"]=@"Prepare fresh genuine engine login, native app subscription and helper for the original game's pending SDK Init; never invoke SDK initialization here";
        [report removeObjectForKey:@"game_main_called"];
        [report removeObjectForKey:@"process_restart_required_after_probe"];
        report[@"game_main_called_by_session"]=@NO;report[@"original_game_main_already_active_required"]=@YES;
        report[@"SteamInternal_SteamAPI_Init_called"]=@NO;
        report[@"process_lifetime_session_requested"]=@YES;
        report[@"limitations"]=@[@"Ready requires native BLoggedOn, native BIsSubscribedApp for3009300 and real helper registration; original SDK success and gameplay remain unproven.",
            @"RunFrame and image/object references are retained for process lifetime; native shutdown remains unsupported.",
            @"Vendor calls cannot be interrupted; root must terminate if bounded startup/cancellation does not settle.",
            @"GameRuntime cwd stays fixed. Absolute Steam config/log locations do not prove all native cache accesses are confined there."];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:NULL];
    if (!Save(report,progress,@"preconditions",@"starting")) return @{@"status":@"failed",@"failure_code":@"progress_file_unwritable"};
    if (NSThread.isMainThread) return Fail(report,progress,@"background_serial_queue_required_main_must_remain_responsive");
    if (!client) return Fail(report,progress,@"validated_client_handle_required");
    NSArray *arguments=NSProcessInfo.processInfo.arguments;
    BOOL explicitLogin=[arguments containsObject:@"--tfm-steam-login"];
    BOOL playMode=TFMSteamCombinedLaunchRequested();
    BOOL explicitEngine=gameSession ? (playMode && !explicitLogin && ![arguments containsObject:@"--tfm-start-steam-engine"] && ![arguments containsObject:@"--tfm-steam-sdk-probe"]) :
        (!playMode && (login ? explicitLogin : ([arguments containsObject:@"--tfm-start-steam-engine"] && !explicitLogin)));
    BOOL sdkProbe=[arguments containsObject:@"--tfm-steam-sdk-probe"];
    BOOL forceFreshLogin=gameSession && [arguments containsObject:@"--tfm-steam-fresh-login"];
    BOOL combinedGame=[arguments containsObject:@"--tfm-run-main"];
    report[@"explicit_engine_mode"]=@(explicitEngine); report[@"combined_game_main_requested"]=@(combinedGame);
    report[@"isolated_engine_process_required"]=@(!gameSession);
    report[@"base_application_allowed_only_for_isolated_engine"]=@(!gameSession);
    if (!explicitEngine || (!gameSession && combinedGame)) return Fail(report,progress,@"explicit_engine_launch_mode_mismatch");
    if (gameSession && !GameRuntimeCurrentDirectory(documents)) return Fail(report,progress,@"fixed_game_runtime_cwd_required_before_engine_start");
    report[@"original_sdk_probe_requested"]=@(sdkProbe);
    if (sdkProbe) report[@"scope"]=login ? @"Isolated fresh QR/native engine login followed only on actual BLoggedOn by genuine helper/SDK initialization and read-only native subscription/build observations; no game calls" : @"Isolated genuine engine/global-user plus app-local original helper and original SDK initialization; no login, ownership or game calls";
    if (sdkProbe && login) {
        NSMutableArray *limits=[report[@"limitations"] mutableCopy];
        limits[limits.count-1]=@"QR approval is separate from genuine engine BLoggedOn. Native subscription/build observations are recorded separately; combined-game readiness is not claimed.";
        report[@"limitations"]=limits;
    }
    if (login && !onQRCode) return Fail(report,progress,@"qr_image_callback_required");
    bool expected=false;
    if (!atomic_compare_exchange_strong(&ProbeAttempted,&expected,true)) return Fail(report,progress,@"one_probe_attempt_per_process_restart_required");
    for (const char **key=(const char *[]){"STAGE0_SIGNIN","STAGE0_STEAMID","STAGE0_OFFLINE","STAGE0_GAME","AGEPAD_STEAM_ENGINE_ID","AGEPAD_STEAM_ENGINE_NAME","AGEPAD_ENGINE_ANON_TEST","AGEPAD_ENGINE_ANON_GAME",NULL};*key;key++)
        if (getenv(*key)) return Fail(report,progress,@"unexpected_authentication_or_game_test_environment_present");
    uintptr_t factory=(uintptr_t)dlsym(client,"CreateInterface"); Dl_info image={0};
    if (!factory || !dladdr((void *)factory,&image)) return Fail(report,progress,@"factory_export_or_image_identity_unavailable");
    uintptr_t base=(uintptr_t)image.dli_fbase;
    if (!PinnedImageUUID(base) || !GuardFunction(factory,base,&FactoryGuard)) return Fail(report,progress,@"pinned_client_factory_uuid_or_code_guard_failed");
    void *retainedClient=gameSession?dlopen(image.dli_fname,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST):NULL;
    if (gameSession && !retainedClient) return Fail(report,progress,@"game_session_client_image_retention_failed");
    report[@"pinned_factory_guard_passed"]=@YES;
    __block BOOL applicationPrepared=NO,hostReady=NO,appKitOpened=NO,statusExported=NO,applicationAlreadyLaunched=NO;
    __block void *appKitImage=NULL;
    if (!Save(report,progress,gameSession?@"verify_existing_original_winit_application":@"prepare_isolated_engine_application",@"starting")) return Fail(report,progress,@"progress_write_failed");
    dispatch_sync(dispatch_get_main_queue(),^{
        NSURL *frameworks=NSBundle.mainBundle.privateFrameworksURL ?: [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Frameworks" isDirectory:YES];
        NSURL *appKitURL=[frameworks URLByAppendingPathComponent:@"TFMAppKit.dylib"];
        // The game boundary is RTLD_LOCAL. Resolve its concrete image rather
        // than the global namespace; retain this reference for process lifetime.
        void *appKit=dlopen(appKitURL.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        appKitImage=appKit;
        appKitOpened=appKit!=NULL;
        NSDictionary *(*status)(void)=appKit ? (NSDictionary *(*)(void))dlsym(appKit,"TFMAppKitStatus") : NULL;
        statusExported=status!=NULL;
        NSDictionary *before=status ? status() : nil;
        hostReady=[before[@"host_ready"] boolValue];
        applicationAlreadyLaunched=[before[@"launched"] boolValue] || [before[@"running"] boolValue];
        Class winit=NSClassFromString(@"WinitApplication"),baseApplication=NSClassFromString(@"NSApplication");
        SEL selector=sel_registerName("sharedApplication");
        report[@"appkit_image_opened"]=@(appKitOpened); report[@"appkit_status_exported"]=@(statusExported);
        report[@"host_ready"]=@(hostReady); report[@"winit_class_registered"]=@(winit!=Nil);
        report[@"base_application_class_registered"]=@(baseApplication!=Nil);
        report[@"application_class_before"]=before[@"application_class"] ?: @"unavailable";
        report[@"application_already_launched_or_running"]=@(applicationAlreadyLaunched);
        // Winit is registered lazily on some builds. This explicit engine-only
        // process may use the base compatibility singleton and must exit before
        // original Rust main is ever tested; do not invoke Rust init offsets.
        Class preferred=winit ?: baseApplication;
        if (gameSession) {
            void *storage=appKit?dlsym(appKit,"NSApp"):NULL;
            id app=storage?(__bridge id)(*(void **)storage):nil;
            applicationPrepared=hostReady && !applicationAlreadyLaunched && winit && app && object_getClass(app)==winit;
            report[@"application_class_after"]=app?NSStringFromClass(object_getClass(app)):@"not-created";
            report[@"existing_original_winit_singleton_verified"]=@(applicationPrepared);
            report[@"application_singleton_created_by_session"]=@NO;
        } else if (hostReady && !applicationAlreadyLaunched && baseApplication && preferred && [preferred respondsToSelector:selector]) {
            id app=((id(*)(id,SEL))objc_msgSend)(preferred,selector);
            applicationPrepared=app && [app isKindOfClass:baseApplication];
            report[@"application_class_after"]=app ? NSStringFromClass(object_getClass(app)) : @"not-created";
        }
        report[@"application_singleton_prepared"]=@(applicationPrepared);
    });
    if (!Save(report,progress,gameSession?@"existing_original_winit_application_result":@"isolated_engine_application_result",@"starting")) return Fail(report,progress,@"progress_write_failed");
    if (!appKitOpened || !statusExported) return Fail(report,progress,@"concrete_appkit_image_or_status_export_unavailable");
    if (applicationAlreadyLaunched) return Fail(report,progress,@"application_already_launched_requires_fresh_engine_only_process");
    if (!hostReady || !applicationPrepared) return Fail(report,progress,@"host_window_or_isolated_application_singleton_not_ready");
    if (!Save(report,progress,@"prepare_fresh_app_cache",@"starting")) return Fail(report,progress,@"progress_write_failed");
    NSURL *engineDirectory=[documents URLByAppendingPathComponent:@"SteamEngine" isDirectory:YES];
    NSString *expectedDirectory=[documents.URLByResolvingSymlinksInPath.path stringByAppendingPathComponent:@"SteamEngine"];
    if (![engineDirectory.URLByResolvingSymlinksInPath.path isEqual:expectedDirectory]) return Fail(report,progress,@"cache_directory_symlink_outside_expected_documents_location");
    NSURL *cache=[engineDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL *config=[cache URLByAppendingPathComponent:@"config" isDirectory:YES],*logs=[cache URLByAppendingPathComponent:@"logs" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:config withIntermediateDirectories:YES attributes:nil error:NULL] ||
        ![NSFileManager.defaultManager createDirectoryAtURL:logs withIntermediateDirectories:YES attributes:nil error:NULL]) return Fail(report,progress,@"fresh_cache_directories_unwritable");
    NSURL *file=[config URLByAppendingPathComponent:@"config.vdf"];
    NSData *empty=[@"\"InstallConfigStore\"\n{\n}\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (![empty writeToURL:file options:NSDataWritingAtomic error:NULL] ||
        setenv("STEAM_CLIENT_CONFIG_FILE",file.fileSystemRepresentation,1) ||
        setenv("STEAM_CLIENT_LOG_FOLDER",logs.fileSystemRepresentation,1) || (!gameSession && chdir(cache.fileSystemRepresentation))) return Fail(report,progress,@"fresh_cache_configuration_failed");
    report[@"cache_location"]=@"Documents/SteamEngine/fresh-diagnostic-run";
    report[@"fresh_empty_config_created"]=@YES; report[@"steam_specific_config_log_paths_set"]=@YES;
    report[@"cwd_changed_for_isolated_process_lifetime"]=@(!gameSession);
    if (gameSession) {
        report[@"game_runtime_cwd_fixed"]=@(GameRuntimeCurrentDirectory(documents));
        if (![report[@"game_runtime_cwd_fixed"] boolValue]) return Fail(report,progress,@"game_runtime_cwd_changed_during_engine_setup");
    }
    if (!Save(report,progress,@"CreateInterface005_pending",@"starting")) return Fail(report,progress,@"progress_write_failed");
    report[@"factory_called"]=@YES; Save(report,progress,nil,nil);
    int factoryStatus=-1;
    void *engine=((void *(*)(const char *,int *))factory)("CLIENTENGINE_INTERFACE_VERSION005",&factoryStatus);
    report[@"factory_status"]=@(factoryStatus); report[@"factory_returned"]=@YES; uintptr_t engineTable=0;
    if (!Save(report,progress,@"engine_object_and_slot_guards",@"starting")) return Fail(report,progress,@"progress_write_failed");
    if (!engine || factoryStatus!=0 || !GuardObject(engine,base,EngineVTable,EngineRTTI,"12CSteamClient",&engineTable)) return Fail(report,progress,@"factory005_result_or_engine_rtti_vtable_guard_failed");
    for (size_t i=0;i<sizeof EngineGuards/sizeof *EngineGuards;i++)
        if (!GuardFunction(Slot(engineTable,EngineGuards[i].slot),base,&EngineGuards[i])) {
            report[@"failed_abi_method"]=@(EngineGuards[i].name);
            return Fail(report,progress,@"engine_slot_code_guard_failed");
        }
    report[@"engine_slot_guards_passed"]=@YES;
    if (!Save(report,progress,@"CreateGlobalUser_pending",@"starting")) return Fail(report,progress,@"progress_write_failed");
    int32_t pipe=0;
    report[@"global_user_call_made"]=@YES; Save(report,progress,nil,nil);
    int32_t userHandle=((int32_t(*)(void *,int32_t *))Slot(engineTable,2))(engine,&pipe);
    if (userHandle<=0 || pipe<=0) return Fail(report,progress,@"CreateGlobalUser_returned_no_user_or_pipe");
    report[@"global_user_and_pipe_created"]=@YES; // handles themselves are not recorded
    if (!Save(report,progress,@"GetIClientUser_pending",@"starting")) return Fail(report,progress,@"progress_write_failed");
    void *user=((void *(*)(void *,int32_t,int32_t))Slot(engineTable,8))(engine,userHandle,pipe); uintptr_t userTable=0;
    if (!Save(report,progress,@"user_interface_and_named_query_guards",@"starting")) return Fail(report,progress,@"progress_write_failed");
    if (!user || !GuardObject(user,base,UserVTable,UserRTTI,"14IClientUserMap",&userTable)) return Fail(report,progress,@"user_interface_rtti_vtable_guard_failed");
    NSMutableDictionary *methods=[NSMutableDictionary dictionary]; uintptr_t queries[4]={0};
    for (size_t i=0;i<4;i++) {
        int slot=FindQuery(userTable,base,QueryGuards[i].name);
        queries[i]=Slot(userTable,slot);
        if (slot!=QueryGuards[i].slot || !GuardFunction(queries[i],base,&QueryGuards[i])) {
            report[@"failed_abi_method"]=@(QueryGuards[i].name); report[@"discovered_slot"]=@(slot);
            return Fail(report,progress,@"named_user_query_or_code_guard_failed");
        }
        methods[@(QueryGuards[i].name)]=@(slot);
    }
    report[@"named_query_slots"]=methods;
    uintptr_t loginFunction=0,tokenSetter=0,subscriptionFunction=0;
    if (login) {
        for (size_t i=0;i<2;i++) {
            int slot=FindQuery(userTable,base,LoginGuards[i].name); uintptr_t function=Slot(userTable,slot);
            if (slot!=LoginGuards[i].slot || !GuardFunction(function,base,&LoginGuards[i])) {
                report[@"failed_abi_method"]=@(LoginGuards[i].name);
                return Fail(report,progress,@"named_login_method_or_code_guard_failed");
            }
            methods[@(LoginGuards[i].name)]=@(slot);
            if (i==0) loginFunction=function; else tokenSetter=function;
        }
        report[@"login_method_guards_passed"]=@YES;
        if (gameSession || sdkProbe) {
            int slot=FindQuery(userTable,base,SubscriptionGuard.name);subscriptionFunction=Slot(userTable,slot);
            if (slot!=SubscriptionGuard.slot || !GuardFunction(subscriptionFunction,base,&SubscriptionGuard))
                return Fail(report,progress,@"named_native_subscription_method_or_code_guard_failed");
            methods[@(SubscriptionGuard.name)]=@(slot);report[@"native_subscription_method_guards_passed"]=@YES;
        }
    }
    if (!Save(report,progress,@"start_bounded_RunFrame_pump",@"observing")) return Fail(report,progress,@"progress_write_failed");
    TFMSteamEnginePump *pump=[TFMSteamEnginePump new]; pump.engine=engine; pump.runFrame=(void *)Slot(engineTable,19); pump.report=report; pump.progressURL=progress;
    pump.gameSession=gameSession;pump.user=user;pump.clientImage=retainedClient;pump.appKitImage=appKitImage;
    if (gameSession) @synchronized([TFMSteamEnginePump class]) {RetainedGamePump=pump;}
    pump.maximumSeconds=login ? 330 : (sdkProbe ? 25 : 5);
    report[@"maximum_pump_seconds"]=@(pump.maximumSeconds);
    pthread_t thread; void *threadArgument=(void *)CFBridgingRetain(pump);
    if (pthread_create(&thread,NULL,Pump,threadArgument)) { CFBridgingRelease(threadArgument); return Fail(report,progress,@"pump_thread_creation_failed"); }
    NSMutableArray *samples=[NSMutableArray array]; NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;BOOL gameReady=NO;
    __block TFMSteamCredentialRecord *pendingCredential=nil;
    BOOL attemptedSavedLogin=NO,credentialReadFailure=NO;
    @try {
        if (login) {
            if (gameSession) {
                LoginStatus(onStatus,@"loading_saved_steam_sign_in");
                NSDictionary *policy=TFMSteamFreshLoginPolicy();
                @synchronized(report) {
                    report[@"credential_policy"]=policy;
                    report[@"toolkit_token_persistence"]=@"app_private_keychain_requested_for_combined_play_only";
                }
                if (![policy[@"status"] isEqual:@"ok"]) {
                    credentialReadFailure=YES;
                    @synchronized(report) {report[@"failure_code"]=@"saved_steam_login_policy_unavailable";}
                } else if (!forceFreshLogin && ![policy[@"force_fresh_login"] boolValue]) {
                    NSDictionary *load=nil;pendingCredential=TFMSteamCredentialLoad(&load);
                    @synchronized(report) {report[@"credential_load"]=load ?: @{@"status":@"load_diagnostic_missing"};}
                    if (!pendingCredential && ![load[@"status"] isEqual:@"not_found"]) {
                        credentialReadFailure=YES;
                        @synchronized(report) {report[@"failure_code"]=@"saved_steam_credential_unavailable";}
                    }
                } else @synchronized(report) {report[@"saved_credential_read_bypassed_for_fresh_login"]=@YES;}
            }
            attemptedSavedLogin=pendingCredential!=nil;
            TFMSteamFreshTokenConsumer submit=^BOOL(NSString *token,NSString *account,uint64_t identity) {
                if (TFMSteamQRAuthenticationCancelled()) return NO;
                if (gameSession && !pendingCredential) {
                    pendingCredential=TFMSteamCredentialCreate(token,account,identity,NULL);
                    if (!pendingCredential) return NO;
                }
                LoginStatus(onStatus,@"submitting_approved_token");
                if (!Save(report,progress,@"SetLoginToken_pending",@"approved_token_submission")) return NO;
                @synchronized(report) { report[@"logon_functions_called"]=@YES; }
                ((void(*)(void *,const char *,const char *))tokenSetter)(user,token.UTF8String,account.UTF8String);
                if (TFMSteamQRAuthenticationCancelled()) return NO;
                if (!Save(report,progress,@"LogOn_pending",@"approved_token_submission")) return NO;
                if (TFMSteamQRAuthenticationCancelled()) return NO;
                int result=((int(*)(void *,uint64_t))loginFunction)(user,identity);
                @synchronized(report) {
                    report[@"logon_call_result"]=@(result);
                    report[attemptedSavedLogin?@"saved_token_submitted":@"fresh_approved_token_submitted"]=@YES;
                }
                return !TFMSteamQRAuthenticationCancelled(); // Actual login is checked separately.
            };
            NSDictionary *auth=nil;
            if (credentialReadFailure) {
                LoginStatus(onStatus,@"saved_steam_sign_in_unavailable");
                auth=@{@"status":@"saved_credential_unavailable_no_authentication_attempt"};
            } else if (attemptedSavedLogin) {
                LoginStatus(onStatus,@"signing_in_with_saved_steam_sign_in");
                @synchronized(report) {report[@"saved_token_login_attempted"]=@YES;}
                BOOL issued=submit(pendingCredential.refreshToken,pendingCredential.accountName,pendingCredential.steamID);
                auth=@{@"status":issued?@"saved_token_delivered_to_engine":@"saved_token_submission_failed",@"token_consumed_by_engine":@(issued)};
                @synchronized(report) {report[@"saved_authentication"]=auth;}
            } else {
                Save(report,progress,@"fresh_qr_authentication",@"awaiting_user_scan");
                auth=TFMSteamQRAuthenticate(210,onQRCode,onStatus,submit);
                @synchronized(report) {report[@"qr_authentication"]=auth;}
            }
            BOOL delivered=[auth[@"status"] isEqual:@"qr_approved_token_delivered_to_engine"] || [auth[@"status"] isEqual:@"saved_token_delivered_to_engine"];
            if (!delivered) {
                @synchronized(report) {
                    if (!report[@"failure_code"]) report[@"failure_code"]=TFMSteamQRAuthenticationCancelled()?@"steam_engine_logon_cancelled":(attemptedSavedLogin?@"saved_steam_token_submission_failed":@"qr_authentication_failed");
                }
            } else {
                LoginStatus(onStatus,@"waiting_for_engine_logon");
                NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+60;
                BOOL loggedOn=NO;
                while (NSProcessInfo.processInfo.systemUptime<deadline && !TFMSteamQRAuthenticationCancelled()) {
                    NSDictionary *sample=StateSample(report,progress,user,queries,started); if (!sample) break;
                    [samples addObject:sample]; if (samples.count>8) [samples removeObjectAtIndex:0];
                    loggedOn=[sample[@"logged_on"] boolValue];
                    @synchronized(report) { report[@"state_samples"]=[samples copy]; report[@"actual_engine_logged_on"]=@(loggedOn); report[@"actual_engine_connected"]=sample[@"connected"]; }
                    Save(report,progress,@"actual_engine_logon_observation",@"observing");
                    if (loggedOn) break;
                    usleep(500000);
                }
                if (NSProcessInfo.processInfo.systemUptime>=deadline || TFMSteamQRAuthenticationCancelled()) loggedOn=NO;
                if (!loggedOn) @synchronized(report) { report[@"failure_code"]=TFMSteamQRAuthenticationCancelled() ? @"steam_engine_logon_cancelled" : @"steam_engine_logon_timeout"; }
                if (loggedOn && gameSession) {
                    // Token claims are only routing hints. Compare against the
                    // genuine guarded native user after the server logged on.
                    uint64_t nativeIdentity=((uint64_t(*)(void *))queries[3])(user);
                    BOOL identityMatches=pendingCredential && nativeIdentity==pendingCredential.steamID;
                    BOOL inTime=NSProcessInfo.processInfo.systemUptime<deadline && !TFMSteamQRAuthenticationCancelled() && !pump.stop && !pump.progressFailure;
                    @synchronized(report) {report[@"credential_identity_matches_logged_on_user"]=@(identityMatches);}
                    if (!identityMatches || !inTime) {
                        loggedOn=NO;
                        @synchronized(report) {report[@"failure_code"]=identityMatches?@"credential_commit_cancelled_or_late":@"credential_identity_mismatch_with_native_user";}
                    } else if (!attemptedSavedLogin) {
                        LoginStatus(onStatus,@"saving_steam_sign_in");
                        NSDictionary *saved=nil;
                        BOOL committed=NO;
                        if (!TFMSteamQRAuthenticationCancelled()) committed=TFMSteamCredentialSave(pendingCredential,&saved);
                        else saved=@{@"status":@"credential_save_cancelled",@"saved":@NO};
                        @synchronized(report) {report[@"credential_save"]=saved ?: @{@"status":@"save_diagnostic_missing"};}
                        LoginStatus(onStatus,committed?@"steam_sign_in_saved":@"steam_sign_in_not_saved");
                    }
                    pendingCredential=nil;
                }
                BOOL subscriptionReady=loggedOn && !(gameSession || sdkProbe);
                if (loggedOn && (gameSession || sdkProbe) && !TFMSteamQRAuthenticationCancelled())
                    subscriptionReady=WaitForNativeSubscription(report,progress,user,base,queries[0],subscriptionFunction,pump,onStatus);
                if (loggedOn && subscriptionReady && gameSession && !TFMSteamQRAuthenticationCancelled()) {
                    LoginStatus(onStatus,@"preparing_game_steam_helper");
                    NSURL *ipcURL=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"TFMSteamIPC.dylib"];
                    void *ipc=dlopen(ipcURL.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);pump.ipcImage=ipc;
                    NSDictionary *(*prepare)(void *,void *,BOOL(*)(void))=ipc?dlsym(ipc,"TFMSteamIPCPrepareForGame"):NULL;
                    if (!prepare) {
                        @synchronized(report) {report[@"failure_code"]=@"shared_steam_ipc_game_preparation_export_missing";}
                    } else if (Save(report,progress,@"genuine_helper_preparation_original_sdk_deferred",@"observing")) {
                        NSDictionary *result=prepare(client,user,TFMSteamQRAuthenticationCancelled);
                        @synchronized(report) {
                            report[@"game_ipc_preparation"]=result ?: @{@"status":@"failed",@"failure_code":@"nil_ipc_preparation_report"};
                            report[@"SteamInternal_SteamAPI_Init_called"]=result[@"sdk_init_called"] ?: @NO;
                            report[@"actual_engine_logged_on"]=result[@"actual_engine_logged_on_at_helper_ready"] ?: @NO;
                            report[@"last_verified_logon_uptime"]=result[@"verified_logon_uptime"] ?: @0;
                        }
                        gameReady=[result[@"status"] isEqual:@"game_ipc_helper_ready_original_sdk_not_called"] &&
                            [result[@"helper_service_ready"] boolValue] && [result[@"actual_engine_logged_on_at_helper_ready"] boolValue] &&
                            ![result[@"sdk_init_called"] boolValue] && !TFMSteamQRAuthenticationCancelled() && GameRuntimeCurrentDirectory(documents);
                        if (!gameReady) @synchronized(report) {report[@"failure_code"]=@"genuine_game_helper_logon_or_cwd_not_ready";}
                        else pump.processLifetime=YES;
                    } else @synchronized(report) {report[@"failure_code"]=@"progress_write_failed_before_game_helper_preparation";}
                }
                if (loggedOn && subscriptionReady && sdkProbe && !TFMSteamQRAuthenticationCancelled()) {
                    LoginStatus(onStatus,@"checking_original_steam_sdk");
                    NSURL *ipcURL=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"TFMSteamIPC.dylib"];
                    void *ipc=dlopen(ipcURL.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
                    NSDictionary *(*probeAfterLogon)(void *,void *,BOOL(*)(void))=ipc?dlsym(ipc,"TFMSteamIPCProbeAfterLogon"):NULL;
                    if (!probeAfterLogon) {
                        @synchronized(report) {report[@"failure_code"]=@"shared_steam_ipc_after_logon_export_missing";}
                    } else if (Save(report,progress,@"original_helper_and_sdk_after_real_logon_pending",@"observing")) {
                        NSDictionary *result=probeAfterLogon(client,user,TFMSteamQRAuthenticationCancelled);
                        @synchronized(report) {
                            report[@"original_sdk_probe"]=result ?: @{@"status":@"failed",@"failure_code":@"nil_ipc_report"};
                            report[@"SteamInternal_SteamAPI_Init_called"]=result[@"sdk_init_called"] ?: @NO;
                            report[@"ownership_queried"]=@([report[@"ownership_queried"] boolValue] || [result[@"ownership_queried"] boolValue]);
                            report[@"sdk_probe_after_observed_native_logon"]=@YES;
                            if (![result[@"status"] isEqual:@"sdk_initialized_after_genuine_engine_logon"])
                                report[@"failure_code"]=@"original_sdk_after_real_logon_probe_failed";
                        }
                    } else @synchronized(report) {report[@"failure_code"]=@"progress_write_failed_before_post_logon_sdk_probe";}
                }
                if (TFMSteamQRAuthenticationCancelled()) @synchronized(report) {report[@"failure_code"]=@"steam_engine_logon_cancelled";}
            }
        } else {
            if (sdkProbe) {
                // One shared dylib owns the service/lookup state. Do not link
                // another SteamIPC.m copy into this executable or the shims.
                NSURL *ipcURL=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"TFMSteamIPC.dylib"];
                void *ipc=dlopen(ipcURL.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
                NSDictionary *(*probe)(void *)=ipc?dlsym(ipc,"TFMSteamIPCProbe"):NULL;
                if (!probe) {
                    @synchronized(report) {report[@"failure_code"]=@"shared_steam_ipc_probe_image_or_export_missing";}
                } else if (Save(report,progress,@"original_helper_and_sdk_probe_pending",@"observing")) {
                    NSDictionary *result=probe(client);
                    @synchronized(report) {
                        report[@"original_sdk_probe"]=result ?: @{@"status":@"failed",@"failure_code":@"nil_ipc_report"};
                        report[@"SteamInternal_SteamAPI_Init_called"]=result[@"sdk_init_called"] ?: @NO;
                        report[@"ownership_queried"]=@([result[@"ownership_queried"] boolValue]);
                        if (![result[@"status"] isEqual:@"sdk_initialized_no_login_or_ownership_claim"])
                            report[@"failure_code"]=@"original_sdk_initialization_probe_failed";
                    }
                } else @synchronized(report) {report[@"failure_code"]=@"progress_write_failed_before_sdk_probe";}
            }
            for (int sampleIndex=0;sampleIndex<2;sampleIndex++) {
                usleep(sampleIndex ? 1750000 : 250000);
                NSDictionary *sample=StateSample(report,progress,user,queries,started); if (!sample) break;
                [samples addObject:sample];
                @synchronized(report) { report[@"state_samples"]=[samples copy]; }
                Save(report,progress,@"state_sample_recorded",@"observing");
            }
        }
    } @catch (__unused NSException *exception) {
        @synchronized(report) { report[@"failure_code"]=@"objective_c_exception_during_observation"; }
    } @finally {
        if (gameSession) {
            BOOL failed=NO;@synchronized(report) {failed=report[@"failure_code"]!=nil;}
            if (!gameReady || failed || TFMSteamQRAuthenticationCancelled()) pump.stop=YES;
            // Retain the pump/image/object owners. Detach even on failure: a
            // vendor RunFrame cannot safely be interrupted or joined within a
            // guaranteed cancellation bound. Root externally terminates if
            // the worker or client threads do not settle.
            pthread_detach(thread);
            @synchronized(report) {report[@"pump_detached"]=@YES;report[@"pump_stop_requested"]=@(pump.stop);}
        } else {
            pump.stop=YES;
            Save(report,progress,@"join_bounded_pump",@"observing");
            pthread_join(thread,NULL);
        }
    }
    @synchronized(report) { report[@"pump_ticks"]=@(pump.ticks); report[@"pump_joined"]=@(!gameSession); }
    NSDictionary *observed;@synchronized(report) {observed=[report copy];}
    if ((!login && samples.count!=2) || (login && ![observed[@"actual_engine_logged_on"] boolValue]) || pump.ticks==0 || pump.progressFailure || observed[@"failure_code"] ||
        (gameSession && (!gameReady || pump.stop || [observed[@"pump_thread_finished"] boolValue]))) {
        if (gameSession) pump.stop=YES;
        if (gameSession) @synchronized(report) {report[@"process_restart_required_after_failure"]=@YES;report[@"native_background_shutdown_proven"]=@NO;}
        NSString *failure=observed[@"failure_code"] ?: @"bounded_observation_incomplete";
        if (login) LoginStatus(onStatus,TFMSteamQRAuthenticationCancelled()?@"cancelled":(credentialReadFailure?@"saved_steam_sign_in_unavailable":(attemptedSavedLogin?@"saved_steam_sign_in_failed_restart_for_qr":@"failed")));
        return Fail(report,progress,failure);
    }
    if (gameSession) {
        @synchronized(report) {
            report[@"pump_retained_for_process_lifetime"]=@YES;report[@"native_image_and_object_references_retained"]=@YES;
            report[@"original_sdk_initialization_deferred_to_game"]=@YES;
        }
        if (!Save(report,progress,@"game_session_ready_original_sdk_deferred",@"game_steam_session_ready_for_original_sdk")) {
            pump.stop=YES;return Fail(report,progress,@"progress_write_failed_at_game_session_ready");
        }
        NSDictionary *snapshot=TFMSteamGameSessionSnapshot();
        if (![snapshot[@"ready"] boolValue]) {pump.stop=YES;return Fail(report,progress,@"game_session_readiness_changed_before_return");}
        LoginStatus(onStatus,@"game_steam_session_ready_for_original_sdk");return snapshot;
    }
    NSString *status=login ? @"steam_engine_logged_on" : (sdkProbe ? @"engine_and_original_sdk_initialized_without_login" : @"engine_started_observed_without_login");
    if (!Save(report,progress,login ? @"completed_real_engine_login" : @"completed_no_login",status)) return Fail(report,progress,@"progress_write_failed_at_completion");
    if (login) LoginStatus(onStatus,status);
    @synchronized(report) {return [report copy];}
}

NSDictionary *TFMSteamEngineProbe(void *client) { return RunEngine(client,NO,NO,nil,nil); }
NSDictionary *TFMSteamEngineQRLogin(void *client,TFMSteamQRCodeHandler onQRCode,TFMSteamAuthStatusHandler onStatus) { return RunEngine(client,YES,NO,onQRCode,onStatus); }
NSDictionary *TFMSteamStartGameSession(void *client,TFMSteamQRCodeHandler onQRCode,TFMSteamAuthStatusHandler onStatus) { return RunEngine(client,YES,YES,onQRCode,onStatus); }
