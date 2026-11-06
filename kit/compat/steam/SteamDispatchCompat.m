#import "SteamDispatchCompat.h"
#import "../UnimplementedBoundary.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef dispatch_source_t (*CreateFunction)(dispatch_source_type_t,uintptr_t,uintptr_t,dispatch_queue_t) __attribute__((ns_returns_retained));
static CreateFunction NativeCreate;
static void (*NativeCancelF)(dispatch_source_t,dispatch_function_t);
static void (*NativeCancelBlock)(dispatch_source_t,dispatch_block_t);
static void *(*NativeContext)(void *); // Opaque C handle: no ARC retain in cancellation.
static void (*NativeCancel)(dispatch_source_t),(*NativeResume)(dispatch_object_t);
static int (*NativeFcntl)(int,int,...),(*NativeClose)(int);
static pthread_mutex_t Lock=PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSValue *,id> *Leases;
static uintptr_t VerifiedClientBase;
static uint64_t Creates,CancelsStarted,CancelsCompleted,Callbacks,Active,CloseSuccess,CloseFailure,Failures,GuardRejections,PassCreate,PassCancel;
static uint64_t OriginalClosedAtCancel;
#ifndef TFM_STEAM_DISPATCH_TESTING
static double LastWrite;
#else
static BOOL FailRegistration;
#endif

@interface TFMDispatchLease : NSObject
@property(nonatomic) void *source; // No object getter/ARC resurrection during cancellation.
@property(nonatomic) int descriptor;
@property(nonatomic) int originalDescriptor;
@property(nonatomic) uintptr_t clientBase;
@property(nonatomic) BOOL writeSource;
@property(nonatomic) BOOL cancelling;
@property(nonatomic) BOOL registered;
@property(nonatomic) dispatch_function_t nativeCancel;
@end
@implementation TFMDispatchLease @end

static BOOL NativeReady(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        void *system=dlopen("/usr/lib/libSystem.B.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        if (!system) return;
        NativeCreate=dlsym(system,"dispatch_source_create");NativeCancelF=dlsym(system,"dispatch_source_set_cancel_handler_f");
        NativeCancelBlock=dlsym(system,"dispatch_source_set_cancel_handler");NativeContext=dlsym(system,"dispatch_get_context");
        NativeCancel=dlsym(system,"dispatch_source_cancel");NativeResume=dlsym(system,"dispatch_resume");
        NativeFcntl=dlsym(system,"fcntl");NativeClose=dlsym(system,"close");
    });
    return NativeCreate && NativeCancelF && NativeCancelBlock && NativeContext && NativeCancel && NativeResume && NativeFcntl && NativeClose;
}
static BOOL Read(uintptr_t address,void *output,size_t count) {
    vm_size_t copied=0;
    return address && count && count<=4096 && address<=UINTPTR_MAX-count &&
        vm_read_overwrite(mach_task_self(),address,count,(vm_address_t)output,&copied)==KERN_SUCCESS && copied==count;
}
static BOOL Hash(uintptr_t address,size_t size,const char *expected) {
    unsigned char bytes[512],digest[CC_SHA256_DIGEST_LENGTH];char hex[65];
    if (size>sizeof bytes || !Read(address,bytes,size)) return NO;
    CC_SHA256(bytes,(CC_LONG)size,digest);
    for (size_t i=0;i<sizeof digest;i++) snprintf(hex+2*i,3,"%02x",digest[i]);
    return !strcmp(hex,expected);
}
static BOOL UUIDMatches(uintptr_t base) {
    static const unsigned char uuid[16]={0x04,0x72,0x94,0x90,0x26,0x58,0x33,0x63,0xbd,0x8d,0x74,0x64,0x21,0xf1,0x04,0x35};
    struct mach_header_64 header={0};
    if (!Read(base,&header,sizeof header) || header.magic!=MH_MAGIC_64 || header.cputype!=CPU_TYPE_ARM64 ||
        header.filetype!=MH_DYLIB || header.ncmds>512 || header.sizeofcmds>65536) return NO;
    uintptr_t cursor=base+sizeof header,end=cursor+header.sizeofcmds;
    for (uint32_t i=0;i<header.ncmds;i++) {
        struct load_command command={0};
        if (cursor>end || end-cursor<sizeof command || !Read(cursor,&command,sizeof command) || command.cmdsize<sizeof command || command.cmdsize>end-cursor) return NO;
        if (command.cmd==LC_UUID) {
            struct uuid_command value={0};return command.cmdsize>=sizeof value && Read(cursor,&value,sizeof value) && !memcmp(value.uuid,uuid,16);
        }
        cursor+=command.cmdsize;
    }return NO;
}
static uintptr_t ScopedCaller(uintptr_t caller,BOOL writeSource) {
    pthread_mutex_lock(&Lock);uintptr_t cached=VerifiedClientBase;pthread_mutex_unlock(&Lock);
    uintptr_t offset=writeSource?0x10c14cc:0x10c14b0;
    if (cached && caller==cached+offset) return cached;
    Dl_info info={0};char actual[PATH_MAX],expected[PATH_MAX];
    if (!dladdr((void *)caller,&info) || !info.dli_fbase || !info.dli_fname || caller!=(uintptr_t)info.dli_fbase+offset) return 0;
    NSURL *path=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"steamclient.dylib"];
    if (!realpath(info.dli_fname,actual) || !realpath(path.fileSystemRepresentation,expected) || strcmp(actual,expected)) return 0;
    uintptr_t base=(uintptr_t)info.dli_fbase;
    BOOL valid=UUIDMatches(base) &&
        Hash(base+0x10c1488,276,"8d21a70cdb0f0e8e9b1815131f0657dcc3568bde7daa6a9f9729bdf6cbfbab1d") &&
        Hash(base+0x10c2cc8,32,"5c46fa58334040bb234d0a0404a499a007eaa4252508c9b936a42ad65133558f") &&
        Hash(base+0x10c2ce8,32,"5c46fa58334040bb234d0a0404a499a007eaa4252508c9b936a42ad65133558f") &&
        Hash(base+0x10c168c,20,"2c9fa35195307bf63c14833b427bac0f474a538c2ba5e741a53aad6339f6f331");
    pthread_mutex_lock(&Lock);if (valid && (!VerifiedClientBase || VerifiedClientBase==base)) VerifiedClientBase=base;else {valid=NO;GuardRejections++;}pthread_mutex_unlock(&Lock);
    return valid?base:0;
}
NSDictionary *TFMSteamDispatchCompatStatus(void) {
    pthread_mutex_lock(&Lock);
    NSDictionary *result=@{@"schema_version":@1,@"scope":@"Pinned native completion-port read/write source descriptor leases; original fd lifetime unchanged",
        @"profile_verified":@(VerifiedClientBase!=0),@"lease_create_count":@(Creates),@"current_leases":@(Active),
        @"cancel_callbacks_started":@(CancelsStarted),@"cancel_callbacks_completed":@(CancelsCompleted),
        @"native_cancel_callback_invocations":@(Callbacks),@"leased_fd_close_count":@(CloseSuccess),@"leased_fd_close_failures":@(CloseFailure),
        @"original_fd_ebadf_at_cancel":@(OriginalClosedAtCancel),@"failure_count":@(Failures),@"guard_rejections":@(GuardRejections),
        @"create_passthrough_count":@(PassCreate),@"cancel_setter_passthrough_count":@(PassCancel),
        @"close_interposed":@NO,@"vendor_instructions_changed":@NO,@"source_get_handle_returns_lease_for_scoped_sources":@YES};
    pthread_mutex_unlock(&Lock);return result;
}
static void Publish(BOOL force) {
#ifndef TFM_STEAM_DISPATCH_TESTING
    struct timespec now={0};clock_gettime(CLOCK_MONOTONIC,&now);double instant=now.tv_sec+now.tv_nsec/1e9;
    pthread_mutex_lock(&Lock);BOOL write=force || instant-LastWrite>=1;if(write)LastWrite=instant;pthread_mutex_unlock(&Lock);
    if (!write) return;
    @autoreleasepool {
        NSDictionary *value=TFMSteamDispatchCompatStatus();
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:NULL];
        if (documents && data) [data writeToURL:[documents URLByAppendingPathComponent:@"steam-dispatch-progress.json"] options:NSDataWritingAtomic error:NULL];
    }
#else
    (void)force;
#endif
}
static void Complete(TFMDispatchLease *lease) {
    @autoreleasepool {
    pthread_mutex_lock(&Lock);
    if (lease.cancelling) {pthread_mutex_unlock(&Lock);return;}
    lease.cancelling=YES;CancelsStarted++;dispatch_function_t callback=lease.nativeCancel;
    int descriptor=lease.descriptor,original=lease.originalDescriptor;
    pthread_mutex_unlock(&Lock);
    // Apple keeps the source alive for its cancellation callout. Do not retain
    // it in this record/block. Preserve the caller's CURRENT native context.
    void *context=NativeContext(lease.source);
    if (callback) {pthread_mutex_lock(&Lock);Callbacks++;pthread_mutex_unlock(&Lock);callback(context);}
    int originalState=NativeFcntl(original,F_GETFD),originalError=errno;
    int closed=NativeClose(descriptor);
    pthread_mutex_lock(&Lock);
    if (originalState<0 && originalError==EBADF) OriginalClosedAtCancel++;
    if (closed==0) CloseSuccess++;else {CloseFailure++;Failures++;}
    lease.descriptor=-1;
    if (lease.registered) {[Leases removeObjectForKey:[NSValue valueWithPointer:lease.source]];Active--;}
    CancelsCompleted++;pthread_mutex_unlock(&Lock);Publish(YES);
    }
}
static dispatch_source_t CreateLease(dispatch_source_type_t type,int original,uintptr_t mask,dispatch_queue_t queue,
    uintptr_t clientBase,CreateFunction create) __attribute__((ns_returns_retained));
static dispatch_source_t CreateLease(dispatch_source_type_t type,int original,uintptr_t mask,dispatch_queue_t queue,
    uintptr_t clientBase,CreateFunction create) {
    TFMDispatchLease *lease=[TFMDispatchLease new];
    if (!lease) {errno=ENOMEM;return nil;}
    int descriptor=NativeFcntl(original,F_DUPFD_CLOEXEC,3);
    if (descriptor<0) {pthread_mutex_lock(&Lock);Failures++;pthread_mutex_unlock(&Lock);return nil;}
    dispatch_source_t source=create(type,(uintptr_t)descriptor,mask,queue);
    if (!source) {int saved=errno;NativeClose(descriptor);pthread_mutex_lock(&Lock);Failures++;pthread_mutex_unlock(&Lock);errno=saved;return nil;}
    lease.source=(__bridge void *)source;lease.descriptor=descriptor;lease.originalDescriptor=original;lease.clientBase=clientBase;lease.writeSource=type==DISPATCH_SOURCE_TYPE_WRITE;
    NativeCancelBlock(source,^{Complete(lease);}); // Own lease before fallible registration.
    pthread_mutex_lock(&Lock);if(!Leases)Leases=[NSMutableDictionary dictionary];BOOL available=Leases!=nil;
#ifdef TFM_STEAM_DISPATCH_TESTING
    if(FailRegistration) {available=NO;FailRegistration=NO;}
#endif
    if(available) {Leases[[NSValue valueWithPointer:(__bridge void *)source]]=lease;lease.registered=YES;Creates++;Active++;}else Failures++;
    pthread_mutex_unlock(&Lock);
    if(!available) {
        // Activate the cancelled inactive source so its default cancel block
        // closes the lease at actual cancellation completion, never earlier.
        NativeCancel(source);NativeResume(source);errno=ENOMEM;return nil;
    }
    Publish(NO);return source;
}
dispatch_source_t TFMSteamSourceCreate(dispatch_source_type_t type,uintptr_t handle,uintptr_t mask,dispatch_queue_t queue)
    __asm__("_dispatch_source_create") __attribute__((ns_returns_retained));
dispatch_source_t TFMSteamSourceCreate(dispatch_source_type_t type,uintptr_t handle,uintptr_t mask,dispatch_queue_t queue) {
    dispatch_source_t result=nil;int saved=ENOSYS;
    @autoreleasepool {
        if(NativeReady()) {
            uintptr_t base=0;
            if ((type==DISPATCH_SOURCE_TYPE_READ || type==DISPATCH_SOURCE_TYPE_WRITE) && handle<=INT_MAX && !mask)
                base=ScopedCaller((uintptr_t)__builtin_return_address(0),type==DISPATCH_SOURCE_TYPE_WRITE);
            if (!base) {pthread_mutex_lock(&Lock);PassCreate++;pthread_mutex_unlock(&Lock);result=NativeCreate(type,handle,mask,queue);}
            else result=CreateLease(type,(int)handle,mask,queue,base,NativeCreate);
            saved=errno;
        }
    }
    errno=saved;return result; // Preserve failure errno even across pool drain.
}
void TFMSteamSourceCancelHandler(dispatch_source_t source,dispatch_function_t callback) __asm__("_dispatch_source_set_cancel_handler_f");
void TFMSteamSourceCancelHandler(dispatch_source_t source,dispatch_function_t callback) {
    @autoreleasepool {
    if(!NativeReady()) TFMAbortUnimplementedBoundary("SteamDispatch","native_dispatch_unavailable");
    pthread_mutex_lock(&Lock);TFMDispatchLease *lease=Leases[[NSValue valueWithPointer:(__bridge void *)source]];pthread_mutex_unlock(&Lock);
    if(!lease) {pthread_mutex_lock(&Lock);PassCancel++;pthread_mutex_unlock(&Lock);NativeCancelF(source,callback);return;}
    uintptr_t caller=(uintptr_t)__builtin_return_address(0),expectedCaller=lease.clientBase+(lease.writeSource?0x10c157c:0x10c156c);
    uintptr_t expectedCallback=lease.clientBase+(lease.writeSource?0x10c2ce8:0x10c2cc8);
    if (caller!=expectedCaller || (uintptr_t)callback!=expectedCallback) {
        pthread_mutex_lock(&Lock);GuardRejections++;Failures++;pthread_mutex_unlock(&Lock);Publish(YES);
        TFMAbortUnimplementedBoundary("SteamDispatch","owned_source_cancel_handler_profile_changed");
    }
    pthread_mutex_lock(&Lock);lease.nativeCancel=callback;pthread_mutex_unlock(&Lock);
    }
}
#ifdef TFM_STEAM_DISPATCH_TESTING
dispatch_source_t TFMSteamDispatchTestCreate(dispatch_source_type_t type,int descriptor,dispatch_queue_t queue) {
    if(!NativeReady())return nil;return CreateLease(type,descriptor,0,queue,0,NativeCreate);
}
static dispatch_source_t FailCreate(dispatch_source_type_t type,uintptr_t handle,uintptr_t mask,dispatch_queue_t queue) __attribute__((ns_returns_retained));
static dispatch_source_t FailCreate(dispatch_source_type_t type,uintptr_t handle,uintptr_t mask,dispatch_queue_t queue) {
    (void)type;(void)handle;(void)mask;(void)queue;errno=ENOMEM;return nil;
}
dispatch_source_t TFMSteamDispatchTestCreateFailure(int descriptor) {if(!NativeReady())return nil;return CreateLease(DISPATCH_SOURCE_TYPE_READ,descriptor,0,NULL,0,FailCreate);}
dispatch_source_t TFMSteamDispatchTestRegistrationFailure(int descriptor,dispatch_queue_t queue) __attribute__((ns_returns_retained));
dispatch_source_t TFMSteamDispatchTestRegistrationFailure(int descriptor,dispatch_queue_t queue) {
    if(!NativeReady())return nil;pthread_mutex_lock(&Lock);FailRegistration=YES;pthread_mutex_unlock(&Lock);
    return CreateLease(DISPATCH_SOURCE_TYPE_READ,descriptor,0,queue,0,NativeCreate);
}
void TFMSteamDispatchTestSetCancel(dispatch_source_t source,dispatch_function_t callback) {
    pthread_mutex_lock(&Lock);TFMDispatchLease *lease=Leases[[NSValue valueWithPointer:(__bridge void *)source]];lease.nativeCancel=callback;pthread_mutex_unlock(&Lock);
}
#endif
