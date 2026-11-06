#import "SteamSDKBoundaryHost.h"
#import "../compat/steam/SteamLaunchPolicy.h"
#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static void *BoundaryImage;
static NSDictionary *(*Snapshot)(void);
static NSString *PreparationStatus=@"not_prepared";
static BOOL Prepared;

static BOOL OwnedExport(void *symbol,const char *path,void **base) {
    Dl_info info={0};char expected[PATH_MAX],actual[PATH_MAX];
    if (!symbol || !dladdr(symbol,&info) || !info.dli_fname ||
        !realpath(path,expected) || !realpath(info.dli_fname,actual) || strcmp(expected,actual)) return NO;
    if (*base && *base!=info.dli_fbase) return NO;
    *base=info.dli_fbase;return YES;
}
BOOL TFMPrepareSteamSDKBoundary(void) {
    if (!NSThread.isMainThread) return NO;
    if (Prepared) return YES;
    NSURL *path=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"TFMSteamSDKClientBoundary.dylib"];
    BOOL requested=TFMSteamSDKClientOrderFixRequested();
    if (![NSFileManager.defaultManager fileExistsAtPath:path.path]) {
        PreparationStatus=requested?@"requested_boundary_missing":@"not_bundled";
        Prepared=!requested;return Prepared;
    }
    BoundaryImage=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    BOOL (*configure)(void *(*)(void *,const char *))=BoundaryImage?dlsym(BoundaryImage,"TFMSteamSDKClientBoundaryConfigure"):NULL;
    NSDictionary *(*snapshot)(void)=BoundaryImage?dlsym(BoundaryImage,"TFMSteamSDKClientBoundarySnapshot"):NULL;
    void *base=NULL;
    if (!OwnedExport((void *)configure,path.fileSystemRepresentation,&base) ||
        !OwnedExport((void *)snapshot,path.fileSystemRepresentation,&base)) {
        PreparationStatus=@"concrete_boundary_exports_unavailable";return NO;
    }
    // This executable imports the actual Apple libSystem. Supplying its resolver
    // explicitly avoids recursion through the SDK-only provider's dlsym export.
    Snapshot=snapshot; // Also expose guard diagnostics when configuration fails.
    if (!configure(dlsym)) { PreparationStatus=@"native_resolver_configuration_rejected";return NO; }
    Prepared=YES;PreparationStatus=@"configured_before_original_sdk_load";
    return YES;
}
NSDictionary *TFMSteamSDKBoundaryObservation(void) {
    NSMutableDictionary *result=[@{@"host_status":PreparationStatus} mutableCopy];
    if (Snapshot) result[@"boundary"]=Snapshot() ?: @{@"status":@"snapshot_unavailable"};
    return result;
}
