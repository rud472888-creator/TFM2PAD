#import "SteamLoaderProbe.h"
#import "SteamSDKBoundaryHost.h"
#import "../compat/steam/SteamEngineProbe.h"
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

static NSDictionary *LoadSteam(UIView *host, BOOL startEngine, BOOL login, void (^onQRCode)(UIImage *), void (^onStatus)(NSString *)) {
    NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSMutableDictionary *report = [@{@"status": @"preparing", @"pid": @(getpid()),
        @"started_at_unix": @(NSDate.date.timeIntervalSince1970), @"engine_start_called": @NO,
        @"create_interface_called": @NO, @"login_performed": @NO,
        @"scope": @"Load the user's staged genuine Steam client image and resolve CreateInterface. Library initializers may execute. No engine start, IPC setup, interface call, or login is requested."} mutableCopy];
    void (^save)(void) = ^{
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL]
            writeToURL:[documents URLByAppendingPathComponent:@"steam-loader-progress.json"] atomically:YES];
    };
    save();
    if (!NSThread.isMainThread || !host.window) { report[@"status"] = @"invalid_host"; save(); return report; }
    // The native client caches SteamAppId on first initialization. Select the
    // actual game before any owned SDK/client image can initialize; this is
    // application identity, not an ownership or authentication answer.
    if (setenv("SteamAppId","3009300",1) || setenv("SteamGameId","3009300",1)) {
        report[@"status"]=@"app_id_environment_failed";save();return report;
    }
    report[@"app_id_selected_before_vendor_load"]=@3009300;
    if (!TFMPrepareSteamSDKBoundary()) {
        report[@"status"]=@"steam_sdk_boundary_preparation_failed";
        report[@"sdk_client_boundary"]=TFMSteamSDKBoundaryObservation();save();return report;
    }
    NSString *frameworks = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSString *clientPath = [frameworks stringByAppendingPathComponent:@"steamclient.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:clientPath]) { report[@"status"] = @"client_not_bundled"; save(); return report; }
    freopen([[documents URLByAppendingPathComponent:@"steam-loader.log"] fileSystemRepresentation], "w", stdout);
    dup2(fileno(stdout), fileno(stderr)); setvbuf(stdout, NULL, _IONBF, 0);
    NSString *gamePath = [frameworks stringByAppendingPathComponent:@"TeamfightManager2.dylib"];
    void *game = dlopen(gamePath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    void (*setHost)(UIWindow *) = game ? dlsym(game, "TFMAppKitSetHostWindow") : NULL;
    if (!game || !setHost) {
        report[@"status"] = @"host_bridge_load_failed"; report[@"error"] = @(dlerror() ?: "host bridge symbol missing"); save(); return report;
    }
    setHost(host.window);
    report[@"status"] = @"loading_steam_client"; save();
    // Keep image registrations and original global objects alive for process lifetime.
    void *client = dlopen(clientPath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!client) {
        report[@"status"] = @"steam_client_load_failed"; report[@"error"] = @(dlerror() ?: "unknown loader error"); save(); return report;
    }
    void *factory = dlsym(client, "CreateInterface");
    Dl_info info = {0};
    BOOL ownExport = factory && dladdr(factory, &info) && info.dli_fname && [@(info.dli_fname).lastPathComponent isEqual:@"steamclient.dylib"];
    report[@"create_interface_export_verified"] = @(ownExport);
    report[@"status"] = ownExport ? @"steam_client_loaded_interface_not_called" : @"steam_client_loaded_factory_missing";
    if (ownExport && startEngine) {
        if (login) [report removeObjectForKey:@"login_performed"];
        [report removeObjectForKey:@"create_interface_called"];
        [report removeObjectForKey:@"engine_start_called"];
        report[@"scope"] = login ? @"Explicit isolated QR login. Approval and real client logon are separate observed stages; restart before game mode." : @"Explicit isolated engine diagnostic. Actual guarded vendor calls are recorded in the separate engine progress file. No login is requested; restart before game mode.";
        report[@"login_requested"] = @(login);
        report[@"engine_progress_file"] = @"Documents/steam-engine-progress.json";
        report[@"status"] = @"engine_probe_scheduled";
        dispatch_queue_t queue = dispatch_queue_create("org.tfm2pad.steam-engine-probe", DISPATCH_QUEUE_SERIAL);
        dispatch_async(queue, ^{
            @autoreleasepool {
                NSDictionary *result = login ? TFMSteamEngineQRLogin(client, onQRCode, onStatus) : TFMSteamEngineProbe(client);
                dispatch_async(dispatch_get_main_queue(), ^{
                    report[@"engine_result_status"] = result[@"status"] ?: @"unknown";
                    report[@"sdk_client_boundary"]=TFMSteamSDKBoundaryObservation();
                    report[@"status"] = @"engine_probe_returned";
                    save();
                    if (onStatus) {
                        NSString *phase=result[@"status"] ?: @"failed";
                        NSDictionary *sdk=result[@"original_sdk_probe"];
                        if ([result[@"actual_engine_logged_on"] boolValue] && [sdk[@"sdk_init_called"] boolValue])
                            phase=[sdk[@"sdk_init_success"] boolValue] ? @"steam_engine_logged_on_sdk_connected" : @"steam_engine_logged_on_sdk_failed";
                        onStatus(phase);
                    }
                });
            }
        });
    }
    save(); return report;
}

NSDictionary *TFMSteamLoaderProbe(UIView *host, BOOL startEngine) {
    return LoadSteam(host,startEngine,NO,nil,nil);
}
NSDictionary *TFMSteamLoginProbe(UIView *host, void (^onQRCode)(UIImage *), void (^onStatus)(NSString *)) {
    return LoadSteam(host,YES,YES,onQRCode,onStatus);
}
