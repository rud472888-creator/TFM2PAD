// Narrow app-local initialization boundary. No Steam interfaces, logon state,
// ownership answers or SDK contexts are implemented or substituted here.
#import "SteamInitBridge.h"
#import "SteamLaunchPolicy.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

static pthread_mutex_t BridgeLock=PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t ModeOnce=PTHREAD_ONCE_INIT,OriginalOnce=PTHREAD_ONCE_INIT;
static BOOL CombinedMode,Configured,AnyInitStarted,CombinedAttempted,CoordinatorRunning;
static BOOL OriginalCalledByCoordinator,OriginalReturnedToCoordinator;
static int OriginalResult;
static pthread_t CoordinatorThread;
static const char *CoordinatorVersions;
static char *CoordinatorError;
static TFMSteamInitCoordinatorFn Coordinator;
static void *CoordinatorContext,*OriginalImage;
static TFMSteamOriginalInitFn OriginalInit;
static _Thread_local BOOL ResolvingOriginal,InOriginalInit;

static int AdapterFailure(char *errorMessage,const char *code,const char *description) {
    // This is an adapter failure before a vendor call, never a claimed SDK
    // result. SteamErrMsg's documented capacity is 1024 bytes.
    if (errorMessage) snprintf(errorMessage,1024,"TFM Steam init bridge: %s",description);
    fprintf(stderr,"TFM_STEAM_INIT_BRIDGE adapter_failure=%s\n",code);fflush(stderr);
    return 1;
}
static void ReadMode(void) {
    @autoreleasepool { CombinedMode=TFMSteamCombinedLaunchRequested(); }
}
static BOOL ReadMemory(uintptr_t address,void *destination,size_t length) {
    if (!address || !destination || !length || address>UINTPTR_MAX-length) return NO;
    vm_size_t read=0;
    return vm_read_overwrite(mach_task_self(),(vm_address_t)address,(vm_size_t)length,
        (vm_address_t)destination,&read)==KERN_SUCCESS && read==length;
}
static BOOL ExecutableRange(uintptr_t address,size_t length) {
    if (!length || address>UINTPTR_MAX-length) return NO;
    vm_address_t region=address;vm_size_t size=0;
    vm_region_basic_info_data_64_t info={0};mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t result=vm_region_64(mach_task_self(),&region,&size,VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info,&count,&object);
    if (MACH_PORT_VALID(object)) mach_port_deallocate(mach_task_self(),object);
    return result==KERN_SUCCESS && (info.protection&VM_PROT_EXECUTE) && region<=address &&
        size>=length && address-region<=size-length;
}
static BOOL CanonicalPathEquals(const char *first,const char *second) {
    char a[PATH_MAX],b[PATH_MAX];
    return first && second && realpath(first,a) && realpath(second,b) && !strcmp(a,b);
}
static BOOL GuardOriginal(const struct mach_header *image,uintptr_t *functionOut) {
    static const unsigned char expectedUUID[16]={0xfc,0xa0,0x30,0x22,0x80,0xd7,0x3c,0x01,0x9d,0x12,0x42,0xb8,0x87,0xa9,0x4e,0x65};
    static const unsigned char expectedHash[CC_SHA256_DIGEST_LENGTH]={
        0x19,0xfd,0xea,0x73,0x25,0x7a,0x51,0x13,0x3d,0x77,0x51,0x40,0x3b,0x41,0xb6,0xb6,
        0x91,0xba,0x77,0xe3,0xea,0x8d,0xa8,0xa8,0xe0,0x63,0x90,0xf4,0x02,0x3f,0xfe,0xa1};
    uintptr_t base=(uintptr_t)image;struct mach_header_64 header={0};
    if (!ReadMemory(base,&header,sizeof header) || header.magic!=MH_MAGIC_64 || header.filetype!=MH_DYLIB ||
        header.cputype!=CPU_TYPE_ARM64 || !header.ncmds || header.ncmds>1024 || !header.sizeofcmds || header.sizeofcmds>1024*1024 ||
        base>UINTPTR_MAX-sizeof header-header.sizeofcmds) return NO;
    NSMutableData *commands=[NSMutableData dataWithLength:header.sizeofcmds];
    if (!ReadMemory(base+sizeof header,commands.mutableBytes,commands.length)) return NO;
    const unsigned char *bytes=commands.bytes;size_t cursor=0;BOOL uuidMatched=NO,haveText=NO,haveSection=NO;
    uint64_t textVM=0,sectionVM=0,sectionSize=0;
    for (uint32_t i=0;i<header.ncmds;i++) {
        struct load_command command={0};
        if (cursor>commands.length || commands.length-cursor<sizeof command) return NO;
        memcpy(&command,bytes+cursor,sizeof command);
        if (command.cmdsize<sizeof command || command.cmdsize>commands.length-cursor) return NO;
        if (command.cmd==LC_UUID) {
            struct uuid_command uuid={0};if (command.cmdsize<sizeof uuid || uuidMatched) return NO;
            memcpy(&uuid,bytes+cursor,sizeof uuid);uuidMatched=!memcmp(uuid.uuid,expectedUUID,sizeof expectedUUID);
            if (!uuidMatched) return NO;
        } else if (command.cmd==LC_SEGMENT_64) {
            struct segment_command_64 segment={0};if (command.cmdsize<sizeof segment) return NO;
            memcpy(&segment,bytes+cursor,sizeof segment);
            if (segment.nsects>(command.cmdsize-sizeof segment)/sizeof(struct section_64)) return NO;
            if (!strncmp(segment.segname,"__TEXT",sizeof segment.segname)) {
                if (haveText) return NO;haveText=YES;textVM=segment.vmaddr;
                for (uint32_t j=0;j<segment.nsects;j++) {
                    struct section_64 section={0};memcpy(&section,bytes+cursor+sizeof segment+j*sizeof section,sizeof section);
                    if (!strncmp(section.sectname,"__text",sizeof section.sectname) && !strncmp(section.segname,"__TEXT",sizeof section.segname)) {
                        if (haveSection) return NO;haveSection=YES;sectionVM=section.addr;sectionSize=section.size;
                    }
                }
            }
        }
        cursor+=command.cmdsize;
    }
    const uintptr_t offset=0x38c8;enum { byteCount=64 };
    if (!uuidMatched || !haveText || !haveSection || sectionVM<textVM || sectionVM-textVM>offset ||
        sectionSize<byteCount || offset-(sectionVM-textVM)>sectionSize-byteCount || base>UINTPTR_MAX-offset) return NO;
    uintptr_t function=base+offset;unsigned char code[byteCount],hash[CC_SHA256_DIGEST_LENGTH];
    if (!ExecutableRange(function,byteCount) || !ReadMemory(function,code,sizeof code)) return NO;
    CC_SHA256(code,(CC_LONG)sizeof code,hash);
    if (memcmp(hash,expectedHash,sizeof hash)) return NO;
    *functionOut=function;return YES;
}
static void ResolveOriginal(void) {
    ResolvingOriginal=YES;
    @autoreleasepool {
        NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TFMOriginalSteamAPI.dylib"];
        OriginalImage=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        if (OriginalImage) {
            const struct mach_header *header=NULL;
            for (uint32_t i=0;i<_dyld_image_count();i++) if (CanonicalPathEquals(_dyld_get_image_name(i),path.fileSystemRepresentation)) {
                if (header) { header=NULL;break; }header=_dyld_get_image_header(i);
            }
            uintptr_t function=0;Dl_info owner={0};
            if (header && GuardOriginal(header,&function) && dladdr((void *)function,&owner) &&
                owner.dli_fbase==header && CanonicalPathEquals(owner.dli_fname,path.fileSystemRepresentation)) OriginalInit=(TFMSteamOriginalInitFn)function;
        }
        // Keep the concrete image loaded for process lifetime. No RTLD_DEFAULT,
        // RTLD_NEXT or generic symbol lookup can substitute another function.
    }
    ResolvingOriginal=NO;
}
BOOL TFMSteamConfigureInitCoordinator(TFMSteamInitCoordinatorFn coordinator,void *context) {
    if (!NSThread.isMainThread || !coordinator) return NO;
    pthread_mutex_lock(&BridgeLock);
    BOOL allowed=!Configured && !AnyInitStarted;
    if (allowed) { Coordinator=coordinator;CoordinatorContext=context;Configured=YES; }
    pthread_mutex_unlock(&BridgeLock);return allowed;
}
static int CallOriginalForCoordinator(const char *versions,char *errorMessage) {
    pthread_mutex_lock(&BridgeLock);
    BOOL allowed=CoordinatorRunning && pthread_equal(CoordinatorThread,pthread_self()) &&
        !OriginalCalledByCoordinator && versions==CoordinatorVersions && errorMessage==CoordinatorError && OriginalInit;
    if (!allowed) { pthread_mutex_unlock(&BridgeLock);return AdapterFailure(errorMessage,"original_call_contract_rejected","coordinator original-init call rejected (thread, arguments or one-call contract)."); }
    OriginalCalledByCoordinator=YES;TFMSteamOriginalInitFn function=OriginalInit;
    pthread_mutex_unlock(&BridgeLock);
    InOriginalInit=YES;int result=function(versions,errorMessage);InOriginalInit=NO;
    pthread_mutex_lock(&BridgeLock);OriginalResult=result;OriginalReturnedToCoordinator=YES;pthread_mutex_unlock(&BridgeLock);
    return result;
}
int SteamInternal_SteamAPI_Init(const char *versions,char *errorMessage) {
    if (ResolvingOriginal) return AdapterFailure(errorMessage,"recursive_image_resolution","recursive original SDK image resolution is unsupported.");
    if (InOriginalInit) return AdapterFailure(errorMessage,"recursive_original_init","recursive entry from original SDK initialization is unsupported.");
    pthread_once(&ModeOnce,ReadMode);
    pthread_mutex_lock(&BridgeLock);AnyInitStarted=YES;
    if (!CombinedMode) {
        pthread_mutex_unlock(&BridgeLock);pthread_once(&OriginalOnce,ResolveOriginal);
        if (!OriginalInit) return AdapterFailure(errorMessage,"original_image_guard_failed","concrete original SDK image/code verification failed; original init was not called.");
        // Existing modes retain the vendor's invocation count, arguments,
        // thread and return/error semantics. No coordinator is involved.
        InOriginalInit=YES;int result=OriginalInit(versions,errorMessage);InOriginalInit=NO;return result;
    }
    if (!NSThread.isMainThread || CombinedAttempted || !Configured) {
        const char *reason=!NSThread.isMainThread?"combined_init_requires_main_thread":(CombinedAttempted?"combined_init_already_attempted":"combined_coordinator_not_registered");
        pthread_mutex_unlock(&BridgeLock);
        return AdapterFailure(errorMessage,reason,"combined initialization requires a registered coordinator, main thread and one fresh process attempt.");
    }
    CombinedAttempted=YES;TFMSteamInitCoordinatorFn callback=Coordinator;void *context=CoordinatorContext;
    pthread_mutex_unlock(&BridgeLock);pthread_once(&OriginalOnce,ResolveOriginal);
    if (!OriginalInit) return AdapterFailure(errorMessage,"original_image_guard_failed","concrete original SDK image/code verification failed; original init was not called.");
    pthread_mutex_lock(&BridgeLock);CoordinatorThread=pthread_self();CoordinatorVersions=versions;CoordinatorError=errorMessage;
    OriginalCalledByCoordinator=NO;OriginalReturnedToCoordinator=NO;CoordinatorRunning=YES;pthread_mutex_unlock(&BridgeLock);
    BOOL threw=NO;
    @try { (void)callback(versions,errorMessage,CallOriginalForCoordinator,context); }
    @catch (__unused NSException *exception) { threw=YES; }
    pthread_mutex_lock(&BridgeLock);CoordinatorRunning=NO;BOOL returned=OriginalReturnedToCoordinator;int result=OriginalResult;
    CoordinatorVersions=NULL;CoordinatorError=NULL;pthread_mutex_unlock(&BridgeLock);
    if (returned) return result;
    return AdapterFailure(errorMessage,threw?"coordinator_exception_before_sdk":"coordinator_stopped_before_sdk",
        "combined-mode coordinator stopped before original SDK initialization; this is an adapter failure, not a vendor SDK result.");
}
