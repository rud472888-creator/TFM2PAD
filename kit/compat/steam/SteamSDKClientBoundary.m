// App-owned ABI forwarding object for one demonstrated SDK init call-site bug.
// SteamClient020 alone has an app-owned forwarding facade; User/Apps objects,
// underlying calls and status results come from the original native libraries.
// No vendor instructions, global vtables, contexts or ownership values change.
#import "SteamSDKClientBoundary.h"
#import "SteamLaunchPolicy.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

enum { ClientSlots=42 };
typedef void *(*NativeFactory)(const char *,int *);
typedef void *(*NativeGetUser)(void *,int32_t,int32_t,const char *);
typedef struct { uintptr_t base,text;size_t textSize; } ImageProfile;
typedef struct { const void *const *vtable;void *nativeObject; } ForwardObject;
_Static_assert(offsetof(ForwardObject,nativeObject)==8,"ARM64 forwarding object layout changed");
static pthread_mutex_t StateLock=PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t ModeOnce=PTHREAD_ONCE_INIT;
static TFMSteamNativeDlsym SystemDlsym;
static void *SystemImage;
static BOOL Enabled,AppleResolverVerified,SDKVerified,ClientVerified,NativeVTableVerified;
static ImageProfile SDK,Client;
static NativeFactory GenuineFactory;
static NativeGetUser GenuineGetUser;
static ForwardObject ForwardClient;
static pthread_t InitThread;
static BOOL InitPending,LastUserNonnull;
static NSDictionary *LastConfigurationDiagnostics;
static uint64_t ConfigureCalls,Lookups,LookupPassthrough,FactoryLookupAdaptations,RejectedGuards;
static uint64_t FactoryCalls,FactoryPassthrough,ForwardObjectsReturned,Slot5Calls,Slot5Passthrough,Slot5Adaptations,NativeUserNonnull;

static const uintptr_t ExpectedSlots[ClientSlots]={
    0x7c96d4,0x7c96f0,0x7c9724,0x7c9750,0x7c9784,0x7c97c4,0x7c97e0,0x7c97fc,
    0x7c9830,0x7c984c,0x7c985c,0x7c9878,0x7c9894,0x7c98a8,0x7c98c4,0x7c98e0,
    0x7c98fc,0x7c9918,0x7c9934,0x7c9950,0x7c996c,0x7c9988,0x7c99a4,0x7c99d0,
    0x7c99ec,0x7c9a08,0x7c9a24,0x7c9a40,0x7c9a5c,0x7c9a78,0x7c9a94,0x7c9ab0,
    0x7c9acc,0x7c9ad0,0x7c9ad4,0x7c9b00,0x7c9b1c,0x7c9b38,0x7c9b54,0x7c9b70,
    0x7c9b8c,0x7c9ba8};

static void ReadMode(void) { @autoreleasepool { Enabled=TFMSteamSDKClientOrderFixRequested(); } }
static BOOL ReadMemory(uintptr_t address,void *destination,size_t count) {
    if (!address || !destination || !count || address>UINTPTR_MAX-count) return NO;
    vm_size_t copied=0;
    return vm_read_overwrite(mach_task_self(),address,count,(vm_address_t)destination,&copied)==KERN_SUCCESS && copied==count;
}
typedef struct {
    kern_return_t basicResult,recurseResult;
    vm_prot_t basicProtection,leafProtection;
    BOOL validRange,basicContains,leafContains,leafInfoComplete,isSubmap,depthBoundExhausted;
    natural_t depth;unsigned queries;
} ExecutionCheck;
static BOOL ExecutableLeaf(uintptr_t address,size_t count,ExecutionCheck *observed) {
    ExecutionCheck check={.basicResult=KERN_INVALID_ARGUMENT,.recurseResult=KERN_INVALID_ARGUMENT};
    check.validRange=address && count && address<=UINTPTR_MAX-count;
    if (!check.validRange) { if (observed) *observed=check;return NO; }
    // Retain the former basic query as diagnostic evidence. A parent/shared
    // submap's protection is not sufficient evidence about its code leaf.
    vm_address_t start=address;vm_size_t size=0;vm_region_basic_info_data_64_t info={0};
    mach_msg_type_number_t length=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t object=MACH_PORT_NULL;
    check.basicResult=vm_region_64(mach_task_self(),&start,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&length,&object);
    if (MACH_PORT_VALID(object)) mach_port_deallocate(mach_task_self(),object);
    check.basicProtection=info.protection;
    check.basicContains=check.basicResult==KERN_SUCCESS && size>=count && address>=start && address-start<=size-count;
    // Apple's mach/vm_region.h documents increasing nesting_depth when
    // is_submap is returned. Query the ORIGINAL target at each deeper level;
    // never walk to the beginning of an unrelated region. Use stable v0 fields
    // only (protection/is_submap) and fail closed after at most sixteen calls.
    // https://github.com/apple/darwin-xnu/blob/main/osfmk/mach/vm_region.h
    natural_t depth=0;
    for (unsigned i=0;i<16;i++) {
        start=address;size=0;vm_region_submap_info_data_64_t leaf={0};
        length=VM_REGION_SUBMAP_INFO_V0_COUNT_64;
        check.recurseResult=vm_region_recurse_64(mach_task_self(),&start,&size,&depth,(vm_region_recurse_info_t)&leaf,&length);
        check.depth=depth;check.queries=i+1;
        const size_t needed=offsetof(vm_region_submap_info_data_64_t,is_submap)+sizeof leaf.is_submap;
        check.leafInfoComplete=(size_t)length*sizeof(natural_t)>=needed;
        check.leafContains=check.recurseResult==KERN_SUCCESS && size>=count && address>=start && address-start<=size-count;
        if (check.recurseResult!=KERN_SUCCESS || !check.leafInfoComplete || !check.leafContains) {
            if (observed) *observed=check;return NO;
        }
        check.leafProtection=leaf.protection;check.isSubmap=leaf.is_submap;
        if (!leaf.is_submap) { if (observed) *observed=check;return (leaf.protection&VM_PROT_EXECUTE)!=0; }
        if (depth>=16 || i==15) { check.depthBoundExhausted=YES;break; }
        depth++;
    }
    if (observed) *observed=check;return NO;
}
static BOOL Executable(uintptr_t address,size_t count) { return ExecutableLeaf(address,count,NULL); }
static NSDictionary *ExecutionDiagnostics(ExecutionCheck check) {
    return @{@"method":@"bounded_vm_region_recurse_64_leaf",@"requested_range_valid":@(check.validRange),
        @"basic_query_result":@(check.basicResult),@"basic_protection":@(check.basicProtection),@"basic_contains_range":@(check.basicContains),
        @"basic_protection_has_execute":@((check.basicProtection&VM_PROT_EXECUTE)!=0),
        @"recurse_query_result":@(check.recurseResult),@"recurse_protection":@(check.leafProtection),
        @"recurse_contains_range":@(check.leafContains),@"recurse_info_complete":@(check.leafInfoComplete),
        @"recurse_is_submap":@(check.isSubmap),@"recurse_depth":@(check.depth),@"recurse_queries":@(check.queries),
        @"recurse_protection_has_execute":@((check.leafProtection&VM_PROT_EXECUTE)!=0),@"depth_bound_exhausted":@(check.depthBoundExhausted)};
}
static BOOL HashMatches(uintptr_t address,size_t count,const char *expected) {
    if (!count || count>32*1024*1024 || strlen(expected)!=64 || address>UINTPTR_MAX-count) return NO;
    CC_SHA256_CTX state;CC_SHA256_Init(&state);unsigned char bytes[4096],hash[CC_SHA256_DIGEST_LENGTH];
    for (size_t offset=0;offset<count;) {
        size_t part=MIN(sizeof bytes,count-offset);
        if (!ReadMemory(address+offset,bytes,part)) return NO;
        CC_SHA256_Update(&state,bytes,(CC_LONG)part);offset+=part;
    }
    CC_SHA256_Final(hash,&state);static const char hex[]="0123456789abcdef";
    for (size_t i=0;i<sizeof hash;i++) if (expected[2*i]!=hex[hash[i]>>4] || expected[2*i+1]!=hex[hash[i]&15]) return NO;
    return YES;
}
static BOOL CanonicalPath(const char *path,NSString *expected) {
    char first[PATH_MAX],second[PATH_MAX];
    return path && realpath(path,first) && realpath(expected.fileSystemRepresentation,second) && !strcmp(first,second);
}
static BOOL BundledOwner(uintptr_t address,NSString *filename,uintptr_t *base) {
    Dl_info info={0};NSString *expected=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:[@"Frameworks" stringByAppendingPathComponent:filename]];
    if (!dladdr((void *)address,&info) || !info.dli_fbase || !CanonicalPath(info.dli_fname,expected)) return NO;
    *base=(uintptr_t)info.dli_fbase;return YES;
}
static BOOL Metadata(uintptr_t base,const unsigned char expectedUUID[16],ImageProfile *profile) {
    struct mach_header_64 header={0};
    if (!ReadMemory(base,&header,sizeof header) || header.magic!=MH_MAGIC_64 || header.cputype!=CPU_TYPE_ARM64 || header.filetype!=MH_DYLIB ||
        !header.ncmds || header.ncmds>1024 || !header.sizeofcmds || header.sizeofcmds>1024*1024 || base>UINTPTR_MAX-sizeof header-header.sizeofcmds) return NO;
    NSMutableData *commands=[NSMutableData dataWithLength:header.sizeofcmds];
    if (!ReadMemory(base+sizeof header,commands.mutableBytes,commands.length)) return NO;
    const unsigned char *bytes=commands.bytes;size_t offset=0;BOOL uuid=NO,text=NO,section=NO;
    uint64_t textVM=0,sectionVM=0,sectionSize=0;
    for (uint32_t i=0;i<header.ncmds;i++) {
        struct load_command command={0};if (offset>commands.length || commands.length-offset<sizeof command) return NO;
        memcpy(&command,bytes+offset,sizeof command);
        if (command.cmdsize<sizeof command || command.cmdsize>commands.length-offset) return NO;
        if (command.cmd==LC_UUID) {
            struct uuid_command item={0};if (uuid || command.cmdsize<sizeof item) return NO;
            memcpy(&item,bytes+offset,sizeof item);if (memcmp(item.uuid,expectedUUID,16)) return NO;uuid=YES;
        } else if (command.cmd==LC_SEGMENT_64) {
            struct segment_command_64 segment={0};if (command.cmdsize<sizeof segment) return NO;
            memcpy(&segment,bytes+offset,sizeof segment);
            if (segment.nsects>(command.cmdsize-sizeof segment)/sizeof(struct section_64)) return NO;
            if (!strncmp(segment.segname,"__TEXT",16)) {
                if (text) return NO;text=YES;textVM=segment.vmaddr;
                for (uint32_t j=0;j<segment.nsects;j++) {
                    struct section_64 item={0};memcpy(&item,bytes+offset+sizeof segment+j*sizeof item,sizeof item);
                    if (!strncmp(item.sectname,"__text",16) && !strncmp(item.segname,"__TEXT",16)) {
                        if (section) return NO;section=YES;sectionVM=item.addr;sectionSize=item.size;
                    }
                }
            }
        }
        offset+=command.cmdsize;
    }
    if (!uuid || !text || !section || !sectionSize || sectionVM<textVM || sectionVM-textVM>UINTPTR_MAX-base || sectionSize>SIZE_MAX) return NO;
    profile->base=base;profile->text=base+(uintptr_t)(sectionVM-textVM);profile->textSize=(size_t)sectionSize;return YES;
}
static BOOL TextContains(ImageProfile profile,uintptr_t address,size_t length) {
    return profile.textSize>=length && address>=profile.text && address-profile.text<=profile.textSize-length && Executable(address,length);
}
static BOOL SDKProfile(uintptr_t caller,ImageProfile *profile) {
    static const unsigned char uuid[16]={0xfc,0xa0,0x30,0x22,0x80,0xd7,0x3c,0x01,0x9d,0x12,0x42,0xb8,0x87,0xa9,0x4e,0x65};
    uintptr_t base=0;
    if (!BundledOwner(caller,@"libsteam_api.dylib",&base) && !BundledOwner(caller,@"TFMOriginalSteamAPI.dylib",&base)) return NO;
    if (!Metadata(base,uuid,profile) || profile->text!=base+0x1a50 || profile->textSize!=0x8b58 ||
        !HashMatches(profile->text,profile->textSize,"fbd68a63a36129a6754ecb1663381432ba734cd128b32abe6f8761fab6676af5")) return NO;
    return HashMatches(base+0x35f0,16,"23476c60440fb1e8d4f79f42517be317409e1bf2814247018ca2fef73bae9b5b") &&
        HashMatches(base+0x3638,16,"4a3e5dda78c896f15bfbd06b5e348f4ae544a9e8cfb470d067b77f9069febd38") &&
        HashMatches(base+0x3b30,44,"8d61138b0024573ebd9b743d0c34bdd2248c4e732ff9f3426e673b1241bc7a3a");
}
static BOOL ClientProfile(uintptr_t factory,ImageProfile *profile) {
    static const unsigned char uuid[16]={0x04,0x72,0x94,0x90,0x26,0x58,0x33,0x63,0xbd,0x8d,0x74,0x64,0x21,0xf1,0x04,0x35};
    uintptr_t base=0;
    return BundledOwner(factory,@"steamclient.dylib",&base) && Metadata(base,uuid,profile) &&
        profile->text==base+0x8000 && profile->textSize==0x12b51e4 && factory==base+0x10857e0 &&
        TextContains(*profile,factory,64) && HashMatches(factory,64,"4688a93410b24036655a8e2ed0f53cce898e7e29c1af0b06361914b5cd6264c8") &&
        HashMatches(base+0x7c5c28,12,"0ed44a12d359dc5f5fb9e9e11ddc07c9b932f677fb6e1d31bfb6f77c3c0985bf") &&
        HashMatches(base+0x7c97c4,28,"f936e83c3e187fe8a8a706b925dd53a7664373d087ffad3562adfe213fba7e79");
}
static BOOL NativeTable(void *object,ImageProfile client) {
    uintptr_t table=0,slots[ClientSlots];
    if ((uintptr_t)object!=client.base+0x17e5ee0 || !ReadMemory((uintptr_t)object,&table,sizeof table) || table!=client.base+0x17316a8 ||
        !ReadMemory(table,slots,sizeof slots)) return NO;
    for (size_t i=0;i<ClientSlots;i++) if (slots[i]!=client.base+ExpectedSlots[i] || !TextContains(client,slots[i],4)) return NO;
    return YES;
}
static void *AdaptedGetUser(ForwardObject *object,int32_t first,int32_t second,const char *version);
#define TFM_DECLARE_SLOT(n) extern void TFMSDKClientForward##n(void) __attribute__((visibility("hidden")));
TFM_DECLARE_SLOT(0) TFM_DECLARE_SLOT(1) TFM_DECLARE_SLOT(2) TFM_DECLARE_SLOT(3) TFM_DECLARE_SLOT(4)
TFM_DECLARE_SLOT(6) TFM_DECLARE_SLOT(7) TFM_DECLARE_SLOT(8) TFM_DECLARE_SLOT(9) TFM_DECLARE_SLOT(10)
TFM_DECLARE_SLOT(11) TFM_DECLARE_SLOT(12) TFM_DECLARE_SLOT(13) TFM_DECLARE_SLOT(14) TFM_DECLARE_SLOT(15)
TFM_DECLARE_SLOT(16) TFM_DECLARE_SLOT(17) TFM_DECLARE_SLOT(18) TFM_DECLARE_SLOT(19) TFM_DECLARE_SLOT(20)
TFM_DECLARE_SLOT(21) TFM_DECLARE_SLOT(22) TFM_DECLARE_SLOT(23) TFM_DECLARE_SLOT(24) TFM_DECLARE_SLOT(25)
TFM_DECLARE_SLOT(26) TFM_DECLARE_SLOT(27) TFM_DECLARE_SLOT(28) TFM_DECLARE_SLOT(29) TFM_DECLARE_SLOT(30)
TFM_DECLARE_SLOT(31) TFM_DECLARE_SLOT(32) TFM_DECLARE_SLOT(33) TFM_DECLARE_SLOT(34) TFM_DECLARE_SLOT(35)
TFM_DECLARE_SLOT(36) TFM_DECLARE_SLOT(37) TFM_DECLARE_SLOT(38) TFM_DECLARE_SLOT(39) TFM_DECLARE_SLOT(40) TFM_DECLARE_SLOT(41)
#undef TFM_DECLARE_SLOT
#define TFM_SLOT(n) (const void *)TFMSDKClientForward##n
// Own metadata: never impersonate the native object's RTTI or object layout.
// This exact SDK profile only dispatches virtual functions; no RTTI is offered.
static const struct { ptrdiff_t offsetToTop;const void *rtti;const void *slots[ClientSlots]; } ForwardVTable={0,NULL,{
    TFM_SLOT(0),TFM_SLOT(1),TFM_SLOT(2),TFM_SLOT(3),TFM_SLOT(4),(const void *)AdaptedGetUser,
    TFM_SLOT(6),TFM_SLOT(7),TFM_SLOT(8),TFM_SLOT(9),TFM_SLOT(10),TFM_SLOT(11),TFM_SLOT(12),TFM_SLOT(13),
    TFM_SLOT(14),TFM_SLOT(15),TFM_SLOT(16),TFM_SLOT(17),TFM_SLOT(18),TFM_SLOT(19),TFM_SLOT(20),TFM_SLOT(21),
    TFM_SLOT(22),TFM_SLOT(23),TFM_SLOT(24),TFM_SLOT(25),TFM_SLOT(26),TFM_SLOT(27),TFM_SLOT(28),TFM_SLOT(29),
    TFM_SLOT(30),TFM_SLOT(31),TFM_SLOT(32),TFM_SLOT(33),TFM_SLOT(34),TFM_SLOT(35),TFM_SLOT(36),TFM_SLOT(37),
    TFM_SLOT(38),TFM_SLOT(39),TFM_SLOT(40),TFM_SLOT(41)}};
#undef TFM_SLOT

static void *FactoryBoundary(const char *name,int *status) {
    uintptr_t caller=(uintptr_t)__builtin_return_address(0);
    pthread_mutex_lock(&StateLock);FactoryCalls++;NativeFactory factory=GenuineFactory;ImageProfile sdk=SDK,client=Client;pthread_mutex_unlock(&StateLock);
    if (!factory) return NULL;
    void *native=factory(name,status); // Genuine factory/result/status, including all other versions.
    char expected[sizeof "SteamClient020"]={0};
    BOOL candidate=caller==sdk.base+0x3644 && name==(const char *)(sdk.base+0xb5f4) &&
        ReadMemory((uintptr_t)name,expected,sizeof expected) && !memcmp(expected,"SteamClient020",sizeof expected) && native;
    BOOL guarded=candidate && NativeTable(native,client) &&
        HashMatches(sdk.base+0x3638,16,"4a3e5dda78c896f15bfbd06b5e348f4ae544a9e8cfb470d067b77f9069febd38");
    pthread_mutex_lock(&StateLock);
    if (!guarded || ForwardObjectsReturned) {
        FactoryPassthrough++;if (candidate && !guarded) RejectedGuards++;pthread_mutex_unlock(&StateLock);return native;
    }
    ForwardClient.vtable=ForwardVTable.slots;ForwardClient.nativeObject=native;
    GenuineGetUser=(NativeGetUser)(client.base+ExpectedSlots[5]);NativeVTableVerified=YES;
    InitThread=pthread_self();InitPending=YES;ForwardObjectsReturned++;
    pthread_mutex_unlock(&StateLock);return &ForwardClient;
}
static void *AdaptedGetUser(ForwardObject *object,int32_t first,int32_t second,const char *version) {
    uintptr_t caller=(uintptr_t)__builtin_return_address(0);
    pthread_mutex_lock(&StateLock);Slot5Calls++;NativeGetUser getUser=GenuineGetUser;ImageProfile sdk=SDK,client=Client;
    BOOL ownObject=object==&ForwardClient && object->nativeObject;
    BOOL pending=ownObject && InitPending && pthread_equal(InitThread,pthread_self());void *native=ownObject?object->nativeObject:NULL;
    pthread_mutex_unlock(&StateLock);
    if (!getUser || !native) { pthread_mutex_lock(&StateLock);RejectedGuards++;pthread_mutex_unlock(&StateLock);return NULL; }
    int32_t pipe=0,user=0;uintptr_t installedObject=0;char expected[sizeof "SteamUser023"]={0};
    BOOL targetCall=caller==sdk.base+0x3b58;
    BOOL guarded=pending && targetCall && version==(const char *)(sdk.base+0xb686) &&
        ReadMemory((uintptr_t)version,expected,sizeof expected) && !memcmp(expected,"SteamUser023",sizeof expected) &&
        ReadMemory(sdk.base+0x10bc0,&pipe,sizeof pipe) && ReadMemory(sdk.base+0x10bc4,&user,sizeof user) && pipe && user &&
        first==pipe && second==user && ReadMemory(sdk.base+0x10bc8,&installedObject,sizeof installedObject) && installedObject==(uintptr_t)object &&
        NativeTable(native,client) && HashMatches(sdk.base+0x3b30,44,"8d61138b0024573ebd9b743d0c34bdd2248c4e732ff9f3426e673b1241bc7a3a") &&
        HashMatches(client.base+0x7c97c4,28,"f936e83c3e187fe8a8a706b925dd53a7664373d087ffad3562adfe213fba7e79");
    pthread_mutex_lock(&StateLock);
    // Consume the exact init-site opportunity once, even if a guard rejected it.
    if (targetCall && pending) InitPending=NO;
    BOOL adapt=guarded && first!=second;
    if (adapt) Slot5Adaptations++;else { Slot5Passthrough++;if (targetCall && !guarded) RejectedGuards++; }
    pthread_mutex_unlock(&StateLock);
    void *result=getUser(native,adapt?user:first,adapt?pipe:second,version);
    pthread_mutex_lock(&StateLock);LastUserNonnull=result!=NULL;if (result) NativeUserNonnull++;pthread_mutex_unlock(&StateLock);
    return result; // Never wrap, cache, replace or manufacture a SteamUser.
}

extern void *TFMSteamSDKBoundaryDlsym(void *handle,const char *name) __asm__("_dlsym");
typedef struct { void *value;uintptr_t tailCall; } LookupDecision;
__attribute__((visibility("hidden"))) LookupDecision TFMSDKClientLookupDecision(void *handle,const char *name,uintptr_t caller) {
    pthread_once(&ModeOnce,ReadMode);
    pthread_mutex_lock(&StateLock);Lookups++;TFMSteamNativeDlsym resolve=SystemDlsym;pthread_mutex_unlock(&StateLock);
    if (!resolve) { fprintf(stderr,"TFM_STEAM_SDK_BOUNDARY unconfigured_native_resolver=1\n");return (LookupDecision){NULL,0}; }
    if (!Enabled || !name || strcmp(name,"CreateInterface") || (intptr_t)handle<=0) {
        pthread_mutex_lock(&StateLock);LookupPassthrough++;pthread_mutex_unlock(&StateLock);return (LookupDecision){(void *)resolve,1};
    }
    ImageProfile sdk={0},client={0};uintptr_t sdkHandle=0;
    BOOL sdkGuard=SDKProfile(caller,&sdk) && caller==sdk.base+0x35fc &&
        ReadMemory(sdk.base+0x10c78,&sdkHandle,sizeof sdkHandle) && sdkHandle==(uintptr_t)handle;
    if (!sdkGuard) {
        pthread_mutex_lock(&StateLock);RejectedGuards++;LookupPassthrough++;pthread_mutex_unlock(&StateLock);return (LookupDecision){(void *)resolve,1};
    }
    // Caller-relative resolution is irrelevant only for this verified concrete
    // image handle. Every unknown lookup tail-calls Apple with the original LR.
    void *result=resolve(handle,name);
    BOOL guarded=result && ClientProfile((uintptr_t)result,&client);
    pthread_mutex_lock(&StateLock);
    if (!guarded || (SDKVerified && SDK.base!=sdk.base) || (ClientVerified && Client.base!=client.base)) {
        RejectedGuards++;LookupPassthrough++;pthread_mutex_unlock(&StateLock);return (LookupDecision){result,0};
    }
    SDK=sdk;Client=client;SDKVerified=YES;ClientVerified=YES;GenuineFactory=(NativeFactory)result;FactoryLookupAdaptations++;
    pthread_mutex_unlock(&StateLock);return (LookupDecision){FactoryBoundary,0};
}
BOOL TFMSteamSDKClientBoundaryConfigure(TFMSteamNativeDlsym nativeDlsym) {
    pthread_once(&ModeOnce,ReadMode);
    pthread_mutex_lock(&StateLock);ConfigureCalls++;
    if (!NSThread.isMainThread || !nativeDlsym) {
        LastConfigurationDiagnostics=@{@"main_thread":@(NSThread.isMainThread),@"callback_present":@(nativeDlsym!=NULL),@"rejection_stage":@"thread_or_missing_callback"};
        pthread_mutex_unlock(&StateLock);return NO;
    }
    if (SystemDlsym) {
        BOOL same=SystemDlsym==nativeDlsym;
        if (!same) LastConfigurationDiagnostics=@{@"main_thread":@YES,@"callback_present":@YES,@"rejection_stage":@"changed_callback"};
        pthread_mutex_unlock(&StateLock);return same;
    }
    pthread_mutex_unlock(&StateLock);
    Dl_info owner={0},exportOwner={0};BOOL ownerFound=dladdr((void *)nativeDlsym,&owner)!=0;
    BOOL ownerAllowed=ownerFound && owner.dli_fname &&
        (!strcmp(owner.dli_fname,"/usr/lib/system/libdyld.dylib") || !strcmp(owner.dli_fname,"/usr/lib/dyld"));
    ExecutionCheck execution={0};
    BOOL executable=ExecutableLeaf((uintptr_t)nativeDlsym,4,&execution),nonself=(void *)nativeDlsym!=(void *)TFMSteamSDKBoundaryDlsym;
    BOOL apple=ownerAllowed && executable && nonself;
    // Open only the fixed Apple system image for diagnostics. An untrusted or
    // unrecognized callback is never called merely to investigate a rejection.
    void *system=dlopen("/usr/lib/libSystem.B.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    BOOL lookupAttempted=apple && system;void *resolved=lookupAttempted?nativeDlsym(system,"dlsym"):NULL;
    BOOL matched=lookupAttempted && resolved==(void *)nativeDlsym;
    if (resolved) dladdr(resolved,&exportOwner);
    NSString *(^basename)(const char *)=^NSString *(const char *path) { return path?(@(path).lastPathComponent ?: @"unavailable"):@"unavailable"; };
    NSString *(^systemPath)(const char *)=^NSString *(const char *path) {
        return path && (!strncmp(path,"/usr/lib/",9) || !strncmp(path,"/System/Library/",16))?@(path):@"not-system-or-unavailable";
    };
    NSDictionary *diagnostics=@{@"main_thread":@YES,@"callback_present":@YES,
        @"callback_owner_found":@(ownerFound),@"callback_owner_basename":basename(owner.dli_fname),
        @"callback_owner_system_path":systemPath(owner.dli_fname),@"callback_owner_exact_allowlist_match":@(ownerAllowed),
        @"callback_executable":@(executable),@"callback_is_not_boundary_dlsym":@(nonself),
        @"callback_region_check":ExecutionDiagnostics(execution),
        @"concrete_system_image_opened":@(system!=NULL),@"resolver_export_lookup_attempted":@(lookupAttempted),
        @"resolver_export_found":@(resolved!=NULL),@"resolver_export_owner_basename":basename(exportOwner.dli_fname),
        @"resolver_export_owner_system_path":systemPath(exportOwner.dli_fname),@"resolver_export_equals_callback":@(matched),
        @"rejection_stage":matched?@"none":(!ownerAllowed?@"callback_owner":(!executable?@"callback_executable":(!nonself?@"callback_is_self":(!system?@"system_image_open":@"resolver_export_equality"))))};
    pthread_mutex_lock(&StateLock);
    LastConfigurationDiagnostics=diagnostics;
    if (matched && !SystemDlsym) { SystemDlsym=nativeDlsym;SystemImage=system;AppleResolverVerified=YES; }
    BOOL configured=SystemDlsym==nativeDlsym;pthread_mutex_unlock(&StateLock);return configured;
}
NSDictionary *TFMSteamSDKClientBoundarySnapshot(void) {
    pthread_once(&ModeOnce,ReadMode);pthread_mutex_lock(&StateLock);
    NSDictionary *result=@{@"enabled_by_explicit_flag":@(Enabled),@"configured":@(SystemDlsym!=NULL),@"apple_native_resolver_verified":@(AppleResolverVerified),
        @"configuration_diagnostics":LastConfigurationDiagnostics ?: @{@"status":@"not_attempted"},
        @"configure_calls":@(ConfigureCalls),@"dlsym_calls":@(Lookups),@"dlsym_passthrough":@(LookupPassthrough),
        @"factory_lookups_adapted":@(FactoryLookupAdaptations),@"guard_rejections":@(RejectedGuards),
        @"sdk_uuid_text_and_callsite_guards_passed":@(SDKVerified),@"native_client_factory_guards_passed":@(ClientVerified),
        @"native_42_slot_vtable_guard_passed":@(NativeVTableVerified),@"factory_calls":@(FactoryCalls),@"factory_native_passthrough":@(FactoryPassthrough),
        @"app_owned_forwarding_objects_returned":@(ForwardObjectsReturned),@"forwarding_slot_count":@42,
        @"slot5_calls":@(Slot5Calls),@"slot5_native_passthrough":@(Slot5Passthrough),@"slot5_order_adaptations":@(Slot5Adaptations),
        @"last_native_user_returned_nonnull":@(LastUserNonnull),@"native_user_nonnull_returns":@(NativeUserNonnull),
        @"vendor_instructions_written":@NO,@"vendor_global_vtables_written":@NO,@"steam_user_objects_replaced":@NO,
        @"scope":@"SDK-only app-owned SteamClient020 forwarding facade; one guarded init-site pair correction; User/Apps objects and call results remain native; no authentication or ownership conclusion"};
    pthread_mutex_unlock(&StateLock);return result;
}
