// App-local Mach service semantics and op13 registration selectively adapted
// from AgePad IPCSystemCompat.c / SteamEngineHost.c (MIT, Chris Sotraidis 2026).
// Permission notice: NOTICE.md. No relay, PID spoof, token or ownership code.
#import "SteamIPC.h"
#import "SteamLaunchPolicy.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>
#include <errno.h>
#include <signal.h>

static const char ServiceName[]="com.valvesoftware.steam.ipctool";
static pthread_mutex_t ServiceLock=PTHREAD_MUTEX_INITIALIZER;
static mach_port_t Service=MACH_PORT_NULL;
static BOOL Enabled;
static NSUInteger CheckIns,Lookups;
static _Thread_local BOOL HelperThread;
static atomic_bool Attempted;
static atomic_uintptr_t HelperSignalBase;
static atomic_bool HelperSignalScopeVerified;
static atomic_ulong HelperSIGTERMRegistrationsDeclined,SignalPassthroughCalls;
static NSMutableDictionary *Report;
static NSURL *Progress;
static void *SystemImage;
static pthread_once_t SystemOnce=PTHREAD_ONCE_INIT;
static void OpenSystem(void) { SystemImage=dlopen("/usr/lib/libSystem.B.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST); }
static void *SystemFunction(const char *name) { pthread_once(&SystemOnce,OpenSystem);return SystemImage?dlsym(SystemImage,name):NULL; }
typedef void (*TFMSteamSignalHandler)(int);
TFMSteamSignalHandler TFMSteamIPCSignal(int number,TFMSteamSignalHandler handler) __asm__("_signal");
static TFMSteamSignalHandler SignalForCaller(int number,TFMSteamSignalHandler handler,uintptr_t caller) {
    int incomingError=errno;
    uintptr_t base=atomic_load_explicit(&HelperSignalBase,memory_order_acquire);
    if (HelperThread && atomic_load_explicit(&HelperSignalScopeVerified,memory_order_acquire) && base &&
        number==SIGTERM && (uintptr_t)handler==base+0x1acc && caller==base+0x1b6c) {
        // The desktop helper normally owns a process. Here it is one embedded
        // thread, so its SIGTERM cleanup/exit handler cannot own the UIKit host.
        // Reject this unsupported registration truthfully, preserving the host
        // disposition and normal termination. The pinned caller ignores return.
        atomic_fetch_add_explicit(&HelperSIGTERMRegistrationsDeclined,1,memory_order_relaxed);
        errno=ENOTSUP;return SIG_ERR;
    }
    atomic_fetch_add_explicit(&SignalPassthroughCalls,1,memory_order_relaxed);
    TFMSteamSignalHandler (*real)(int,TFMSteamSignalHandler)=SystemFunction("signal");
    if (!real || (void *)real==(void *)TFMSteamIPCSignal) {errno=ENOSYS;return SIG_ERR;}
    errno=incomingError;return real(number,handler);
}
__attribute__((noinline)) TFMSteamSignalHandler TFMSteamIPCSignal(int number,TFMSteamSignalHandler handler) {
    return SignalForCaller(number,handler,(uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0)));
}
static void Fields(NSDictionary *fields) { @synchronized(Report) {[Report addEntriesFromDictionary:fields];} }
static NSDictionary *Snapshot(void) { @synchronized(Report) {return [Report copy];} }

static BOOL Save(NSString *stage,NSString *status) {
    if (!Report || !Progress) return NO;
    @synchronized(Report) {
        if (stage) Report[@"stage"]=stage;
        if (status) Report[@"status"]=status;
        NSData *json=[NSJSONSerialization dataWithJSONObject:Report options:NSJSONWritingSortedKeys|NSJSONWritingPrettyPrinted error:NULL];
        BOOL result=json && [json writeToURL:Progress options:NSDataWritingAtomic error:NULL];
        if (stage) {fprintf(stderr,"TFM_STEAM_IPC stage=%s status=%s\n",stage.UTF8String,[Report[@"status"] UTF8String]);fflush(stderr);}
        return result;
    }
}
static NSDictionary *Failure(NSString *code) {
    @synchronized(Report) {Report[@"failure_code"]=code;}
    Save(nil,@"failed");return Snapshot();
}
NSDictionary *TFMSteamIPCStatus(void) {
    pthread_mutex_lock(&ServiceLock);
    NSDictionary *result=@{@"enabled":@(Enabled),@"service_ready":@(MACH_PORT_VALID(Service)),
        @"successful_check_ins":@(CheckIns),@"successful_local_lookups":@(Lookups),
        @"helper_signal_scope_verified":@(atomic_load_explicit(&HelperSignalScopeVerified,memory_order_acquire)),
        @"helper_sigterm_registrations_declined":@(atomic_load_explicit(&HelperSIGTERMRegistrationsDeclined,memory_order_relaxed)),
        @"signal_passthrough_calls":@(atomic_load_explicit(&SignalPassthroughCalls,memory_order_relaxed)),
        @"host_signal_disposition_changed_by_adapter":@NO};
    pthread_mutex_unlock(&ServiceLock);return result;
}

kern_return_t TFMSteamBootstrapCheckIn(mach_port_t bootstrap,const char *name,mach_port_t *service) __asm__("_bootstrap_check_in");
kern_return_t TFMSteamBootstrapCheckIn(mach_port_t bootstrap,const char *name,mach_port_t *service) {
    pthread_mutex_lock(&ServiceLock);
    BOOL local=Enabled && name && !strcmp(name,ServiceName);
    if (!local) {
        pthread_mutex_unlock(&ServiceLock);
        kern_return_t (*real)(mach_port_t,const char *,mach_port_t *)=SystemFunction("bootstrap_check_in");
        return real?real(bootstrap,name,service):KERN_NOT_SUPPORTED;
    }
    if (!service) {pthread_mutex_unlock(&ServiceLock);return KERN_INVALID_ARGUMENT;}
    *service=MACH_PORT_NULL;
    // Only the guarded genuine helper's own thread may claim this service.
    if (!HelperThread) {pthread_mutex_unlock(&ServiceLock);return KERN_NO_ACCESS;}
    if (MACH_PORT_VALID(Service)) {pthread_mutex_unlock(&ServiceLock);return 1101; /* BOOTSTRAP_SERVICE_ACTIVE */}
    mach_port_t port=MACH_PORT_NULL;
    kern_return_t result=mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port);
    if (result==KERN_SUCCESS) result=mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND);
    if (result==KERN_SUCCESS) {Service=port;*service=port;CheckIns++;}
    else if (MACH_PORT_VALID(port)) mach_port_destroy(mach_task_self(),port);
    pthread_mutex_unlock(&ServiceLock);return result;
}
kern_return_t TFMSteamBootstrapLookUp(mach_port_t bootstrap,const char *name,mach_port_t *service) __asm__("_bootstrap_look_up");
kern_return_t TFMSteamBootstrapLookUp(mach_port_t bootstrap,const char *name,mach_port_t *service) {
    pthread_mutex_lock(&ServiceLock);
    BOOL local=Enabled && name && !strcmp(name,ServiceName);
    if (!local) {
        pthread_mutex_unlock(&ServiceLock);
        kern_return_t (*real)(mach_port_t,const char *,mach_port_t *)=SystemFunction("bootstrap_look_up");
        return real?real(bootstrap,name,service):KERN_NOT_SUPPORTED;
    }
    if (!service) {pthread_mutex_unlock(&ServiceLock);return KERN_INVALID_ARGUMENT;}
    *service=MACH_PORT_NULL;
    if (!MACH_PORT_VALID(Service)) {pthread_mutex_unlock(&ServiceLock);return 1102; /* BOOTSTRAP_UNKNOWN_SERVICE */}
    // Every successful lookup owns one new send-right user reference, exactly
    // as a real service lookup; caller deallocation must not destroy service.
    kern_return_t result=mach_port_mod_refs(mach_task_self(),Service,MACH_PORT_RIGHT_SEND,1);
    if (result==KERN_SUCCESS) {*service=Service;Lookups++;}
    pthread_mutex_unlock(&ServiceLock);return result;
}
static void HelperFinished(int status,BOOL explicitExit) {
    pthread_mutex_lock(&ServiceLock);
    if (MACH_PORT_VALID(Service)) mach_port_destroy(mach_task_self(),Service);
    Service=MACH_PORT_NULL;
    pthread_mutex_unlock(&ServiceLock);
    @synchronized(Report) {Report[@"helper_exited"]=@YES;Report[@"helper_exit_code"]=@(status);Report[@"helper_called_exit"]=@(explicitExit);}
    Save(@"helper_thread_finished",nil);
}
__attribute__((noreturn)) void TFMSteamIPCExit(int status) __asm__("_exit");
__attribute__((noreturn)) void TFMSteamIPCExit(int status) {
    if (HelperThread) {HelperFinished(status,YES);pthread_exit(NULL);}
    void (*real)(int)=SystemFunction("exit");if (real) real(status);__builtin_trap();
}
__attribute__((noreturn)) void TFMSteamIPCImmediateExit(int status) __asm__("__exit");
__attribute__((noreturn)) void TFMSteamIPCImmediateExit(int status) {
    if (HelperThread) {HelperFinished(status,YES);pthread_exit(NULL);}
    void (*real)(int)=SystemFunction("_exit");if (real) real(status);__builtin_trap();
}

static BOOL ReadMemory(uintptr_t address,void *destination,size_t count) {
    vm_size_t copied=0;
    return address && destination && vm_read_overwrite(mach_task_self(),address,count,(vm_address_t)destination,&copied)==KERN_SUCCESS && copied==count;
}
static NSString *MemoryHash(uintptr_t address,size_t count) {
    if (!count || count>1024*1024) return nil;
    NSMutableData *bytes=[NSMutableData dataWithLength:count];
    if (!ReadMemory(address,bytes.mutableBytes,count)) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)count,hash);
    NSMutableString *result=[NSMutableString stringWithCapacity:64];
    for (unsigned i=0;i<sizeof hash;i++) [result appendFormat:@"%02x",hash[i]];
    return result;
}
static BOOL Executable(uintptr_t address) {
    vm_address_t start=address;vm_size_t size=0;vm_region_basic_info_data_64_t info={0};
    mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t object=MACH_PORT_NULL;
    kern_return_t result=vm_region_64(mach_task_self(),&start,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if (MACH_PORT_VALID(object)) mach_port_deallocate(mach_task_self(),object);
    return result==KERN_SUCCESS && address>=start && address<start+size && (info.protection&VM_PROT_READ) && (info.protection&VM_PROT_EXECUTE);
}
static uintptr_t ImageBase(NSURL *url) {
    for (uint32_t i=0;i<_dyld_image_count();i++) {
        const char *name=_dyld_get_image_name(i);
        if (name && !strcmp(name,url.fileSystemRepresentation)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}
static BOOL ImageMetadata(uintptr_t base,NSString **uuidOut,uintptr_t *textOut,size_t *textSizeOut) {
    struct mach_header_64 header={0};
    if (!ReadMemory(base,&header,sizeof header) || header.magic!=MH_MAGIC_64 || header.filetype!=MH_DYLIB || header.cputype!=CPU_TYPE_ARM64 || header.ncmds>1024 || header.sizeofcmds>1024*1024) return NO;
    uintptr_t cursor=base+sizeof header,end=cursor+header.sizeofcmds,textVM=0,sectionVM=0;size_t sectionSize=0;
    NSString *uuid=nil;
    for (uint32_t i=0;i<header.ncmds;i++) {
        struct load_command command;
        if (!ReadMemory(cursor,&command,sizeof command) || command.cmdsize<sizeof command || cursor+command.cmdsize>end) return NO;
        if (command.cmd==LC_UUID) {
            struct uuid_command item;
            if (command.cmdsize<sizeof item || !ReadMemory(cursor,&item,sizeof item)) return NO;
            NSMutableString *value=[NSMutableString string];for (unsigned j=0;j<sizeof item.uuid;j++) [value appendFormat:@"%02x",item.uuid[j]];uuid=value;
        } else if (command.cmd==LC_SEGMENT_64) {
            struct segment_command_64 segment;
            if (command.cmdsize<sizeof segment || !ReadMemory(cursor,&segment,sizeof segment) || segment.nsects>(command.cmdsize-sizeof segment)/sizeof(struct section_64)) return NO;
            if (!strncmp(segment.segname,"__TEXT",16)) {
                if (segment.fileoff!=0) return NO;textVM=segment.vmaddr;
                for (uint32_t s=0;s<segment.nsects;s++) {
                    struct section_64 section;
                    if (!ReadMemory(cursor+sizeof segment+s*sizeof section,&section,sizeof section)) return NO;
                    if (!strncmp(section.sectname,"__text",16)) {sectionVM=section.addr;sectionSize=(size_t)section.size;}
                }
            }
        }
        cursor+=command.cmdsize;
    }
    if (!uuid || sectionVM<textVM || !sectionSize) return NO;
    *uuidOut=uuid;*textOut=base+(sectionVM-textVM);*textSizeOut=sectionSize;return YES;
}
static NSString *SymbolImage(void *pointer) {
    Dl_info info={0};
    if (!pointer) return @"null";
    return dladdr(pointer,&info) && info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname].lastPathComponent : @"unmapped";
}
static BOOL FileRead(NSData *data,size_t offset,void *destination,size_t count) {
    if (offset>data.length || count>data.length-offset) return NO;
    memcpy(destination,(const uint8_t *)data.bytes+offset,count);return YES;
}
static NSString *FileString(NSData *data,size_t offset,size_t limit) {
    if (offset>data.length || limit>data.length-offset) return nil;
    const char *start=(const char *)data.bytes+offset;
    const char *end=memchr(start,0,limit);
    return end?[[NSString alloc] initWithBytes:start length:(NSUInteger)(end-start) encoding:NSUTF8StringEncoding]:nil;
}
// Read only the concrete bundled Mach-O's indirect symbol table and its mapped
// pointer slots. No slot writes, binder calls or vendor function calls occur.
// RTLD_FIRST on the exact ordinal provider is different from generic dlsym on
// the importing image (which also searches Foundation/libc++ dependencies).
static NSDictionary *Binding(NSURL *imageURL,NSString *symbol,NSString *providerName,void *expected,BOOL allowLazy) {
    NSMutableDictionary *result=[@{@"symbol":symbol,@"importing_image":imageURL.lastPathComponent,
        @"expected_provider":providerName,@"verified":@NO,@"slots":@[]} mutableCopy];
    NSData *data=[NSData dataWithContentsOfURL:imageURL options:NSDataReadingMappedIfSafe error:NULL];
    struct mach_header_64 header;struct symtab_command sym={0};struct dysymtab_command dysym={0};
    if (!data || !FileRead(data,0,&header,sizeof header) || header.magic!=MH_MAGIC_64 || header.filetype!=MH_DYLIB || header.ncmds>1024 || header.sizeofcmds>data.length-sizeof header) {
        result[@"failure_code"]=@"malformed_import_image_header";return result;
    }
    NSMutableArray<NSString *> *providers=[NSMutableArray array];NSMutableArray<NSData *> *sections=[NSMutableArray array];
    uint64_t textVM=0,stubVM=0,stubSize=0;size_t cursor=sizeof header,end=cursor+header.sizeofcmds;
    for (uint32_t i=0;i<header.ncmds;i++) {
        struct load_command command;
        if (!FileRead(data,cursor,&command,sizeof command) || command.cmdsize<sizeof command || command.cmdsize>end-cursor) {result[@"failure_code"]=@"malformed_import_load_command";return result;}
        if (command.cmd==LC_SYMTAB) {
            if (command.cmdsize<sizeof sym || !FileRead(data,cursor,&sym,sizeof sym)) return result;
        } else if (command.cmd==LC_DYSYMTAB) {
            if (command.cmdsize<sizeof dysym || !FileRead(data,cursor,&dysym,sizeof dysym)) return result;
        } else if (command.cmd==LC_LOAD_DYLIB || command.cmd==LC_LOAD_WEAK_DYLIB || command.cmd==LC_REEXPORT_DYLIB || command.cmd==LC_LOAD_UPWARD_DYLIB) {
            struct dylib_command dylib;
            if (command.cmdsize<sizeof dylib || !FileRead(data,cursor,&dylib,sizeof dylib) || dylib.dylib.name.offset>=command.cmdsize) return result;
            NSString *path=FileString(data,cursor+dylib.dylib.name.offset,command.cmdsize-dylib.dylib.name.offset);
            if (!path) return result;[providers addObject:path.lastPathComponent];
        } else if (command.cmd==LC_SEGMENT_64) {
            struct segment_command_64 segment;
            if (command.cmdsize<sizeof segment || !FileRead(data,cursor,&segment,sizeof segment) || segment.nsects>(command.cmdsize-sizeof segment)/sizeof(struct section_64)) return result;
            if (!strncmp(segment.segname,"__TEXT",16) && segment.fileoff==0) textVM=segment.vmaddr;
            for (uint32_t j=0;j<segment.nsects;j++) {
                struct section_64 section;
                if (!FileRead(data,cursor+sizeof segment+j*sizeof section,&section,sizeof section)) return result;
                if (!strncmp(section.segname,"__TEXT",16) && !strncmp(section.sectname,"__stub_helper",16)) {stubVM=section.addr;stubSize=section.size;}
                uint32_t type=section.flags&SECTION_TYPE;
                if (type==S_LAZY_SYMBOL_POINTERS || type==S_NON_LAZY_SYMBOL_POINTERS) [sections addObject:[NSData dataWithBytes:&section length:sizeof section]];
            }
        }
        cursor+=command.cmdsize;
    }
    uintptr_t base=ImageBase(imageURL);
    if (!base || !sym.symoff || !dysym.indirectsymoff || sym.nsyms>1000000 || dysym.nindirectsyms>1000000) {result[@"failure_code"]=@"missing_import_tables_or_loaded_image";return result;}
    NSURL *providerURL=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:providerName];
    void *provider=dlopen(providerURL.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    void *providerExport=provider?dlsym(provider,symbol.UTF8String+1):NULL;
    BOOL providerMatches=providerExport==expected;
    result[@"ordinal_provider_lookup_image"]=SymbolImage(providerExport);
    result[@"ordinal_provider_export_matches_expected"]=@(providerMatches);
    NSMutableArray *slots=[NSMutableArray array];BOOL valid=YES;
    for (NSData *encoded in sections) {
        struct section_64 section;[encoded getBytes:&section length:sizeof section];
        if (section.size%sizeof(uintptr_t) || section.size/sizeof(uintptr_t)>65536 || section.addr<textVM) return result;
        for (uint64_t j=0;j<section.size/sizeof(uintptr_t);j++) {
            uint64_t indirect=(uint64_t)section.reserved1+j;uint32_t index=0;
            if (indirect>=dysym.nindirectsyms || !FileRead(data,(size_t)dysym.indirectsymoff+(size_t)indirect*4,&index,sizeof index)) return result;
            if (index&(INDIRECT_SYMBOL_LOCAL|INDIRECT_SYMBOL_ABS)) continue;
            struct nlist_64 item;
            if (index>=sym.nsyms || !FileRead(data,(size_t)sym.symoff+(size_t)index*sizeof item,&item,sizeof item) || item.n_un.n_strx>=sym.strsize) return result;
            NSString *name=FileString(data,(size_t)sym.stroff+item.n_un.n_strx,sym.strsize-item.n_un.n_strx);
            if (![name isEqual:symbol]) continue;
            unsigned ordinal=GET_LIBRARY_ORDINAL(item.n_desc);
            NSString *actualProvider=ordinal>0 && ordinal<=providers.count?providers[ordinal-1]:@"special_or_invalid_ordinal";
            uintptr_t pointer=0;BOOL readable=ReadMemory(base+(section.addr-textVM)+(uintptr_t)j*sizeof pointer,&pointer,sizeof pointer);
            BOOL matched=readable && pointer==(uintptr_t)expected;
            BOOL lazy=readable && (section.flags&SECTION_TYPE)==S_LAZY_SYMBOL_POINTERS && stubVM>=textVM && stubSize && pointer>=base+(stubVM-textVM) && pointer-base-(stubVM-textVM)<stubSize;
            BOOL verified=[actualProvider isEqual:providerName] && providerMatches && (matched || (allowLazy && lazy));
            [slots addObject:@{@"import_library_ordinal":@(ordinal),@"import_provider":actualProvider,
                @"bound_image":SymbolImage((void *)pointer),@"bound_to_expected_shared_definition":@(matched),
                @"lazy_import_not_yet_resolved":@(lazy),@"slot_readable":@(readable),@"verified":@(verified)}];
            if (!verified) valid=NO;
        }
    }
    result[@"slots"]=slots;result[@"verified"]=@(valid && slots.count>0);result[@"lazy_slots_allowed_before_call"]=@(allowLazy);
    if (!slots.count) result[@"failure_code"]=@"required_import_not_present";
    return result;
}
static NSDictionary *SDKBinding(NSURL *sdkURL,void *expected,BOOL allowLazy) {
    NSDictionary *original=Binding(sdkURL,@"_bootstrap_look_up",@"TFMlibSystem.dylib",expected,allowLazy);
    if ([original[@"verified"] boolValue]) return original;
    // Optional SDK-only dlsym boundary reexports the existing game libSystem
    // and therefore the SAME shared IPC implementation. Keep exact import
    // ordinal/provider and actual resolved-function checks; do not accept a
    // process-global lookup merely because the optional file is present.
    NSString *name=@"TFMSteamSDKClientBoundary.dylib";
    NSURL *boundary=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:boundary.path]) return original;
    NSDictionary *adapter=Binding(sdkURL,@"_bootstrap_look_up",name,expected,allowLazy);
    if ([adapter[@"verified"] boolValue]) return adapter;
    return @{@"symbol":@"_bootstrap_look_up",@"verified":@NO,@"allowed_provider_candidates":@[original,adapter],
        @"failure_code":@"sdk_bootstrap_import_does_not_match_either_exact_shared_ipc_provider"};
}
static void *HelperMain(void *entry) {
    @autoreleasepool {
        HelperThread=YES;
        @synchronized(Report) {Report[@"helper_thread_started"]=@YES;}
        Save(@"original_helper_main_pending",nil);
        char *arguments[]={(char *)"ipcserver",NULL};
        int code=((int(*)(int,char **))entry)(1,arguments);
        HelperFinished(code,NO);HelperThread=NO;
    }
    return NULL;
}
static BOOL ProbeLookupReferences(void) {
    mach_port_t a=MACH_PORT_NULL,b=MACH_PORT_NULL;
    kern_return_t first=TFMSteamBootstrapLookUp(MACH_PORT_NULL,ServiceName,&a);
    kern_return_t second=TFMSteamBootstrapLookUp(MACH_PORT_NULL,ServiceName,&b);
    BOOL same=first==KERN_SUCCESS && second==KERN_SUCCESS && a==b;
    if (MACH_PORT_VALID(a)) mach_port_deallocate(mach_task_self(),a);
    if (MACH_PORT_VALID(b)) mach_port_deallocate(mach_task_self(),b);
    pthread_mutex_lock(&ServiceLock);mach_port_type_t type=0;
    BOOL alive=MACH_PORT_VALID(Service) && mach_port_type(mach_task_self(),Service,&type)==KERN_SUCCESS && (type&MACH_PORT_TYPE_RECEIVE);
    pthread_mutex_unlock(&ServiceLock);return same && alive;
}
static NSString *ErrorCategory(const char *error) {
    if (!error[0]) return @"none";
    // Never persist arbitrary vendor error text: it may contain a private path.
    if (!strcmp(error,"ConnectToGlobalUser failed.")) return @"connect_to_global_user_failed";
    if (!strcmp(error,"CreateSteamPipe failed.")) return @"create_steam_pipe_failed";
    if (!strcmp(error,"No appID found.  Either launch the game from Steam, or put the file steam_appid.txt containing the correct appID in your game folder."))
        return @"native_steam_utils_app_id_zero";
    if (strstr(error,"SteamUser023")) return @"steam_user023_interface_unavailable";
    if (strstr(error,"SteamUtils010")) return @"steam_utils010_interface_unavailable";
    if (strstr(error,"install directory")) return @"client_install_directory_unavailable";
    if (strstr(error,"Failed to load module")) return @"client_module_load_failed";
    return @"other_vendor_error_text_redacted";
}
static NSString *ExactErrorInterface(const char *error) {
    // The pinned SDK's error format is literally "No %s". Persist only these
    // audited public interface names, never arbitrary vendor text or paths.
    for (NSString *name in @[@"SteamUser023",@"SteamUtils010",@"STEAMAPPS_INTERFACE_VERSION008"]) {
        NSString *message=[@"No " stringByAppendingString:name];
        if (!strcmp(error,message.UTF8String)) return name;
    }
    return @"none_or_unrecognized";
}

static BOOL RealLoggedOn(uintptr_t clientBase,void *user,BOOL *guardPassed) {
    uintptr_t table=0,function=0;*guardPassed=NO;
    if (!ReadMemory((uintptr_t)user,&table,sizeof table) || table!=clientBase+0x173fe80 ||
        !ReadMemory(table+4*sizeof(uintptr_t),&function,sizeof function) || function!=clientBase+0x891370 || !Executable(function) ||
        ![MemoryHash(function,64) isEqual:@"f0a0ae4c5be3753eb2425c54775122d3e40dffa385792449e8a015647e399a0a"]) return NO;
    *guardPassed=YES;return ((bool(*)(void *))function)(user);
}

typedef struct {const char *name;uintptr_t offset;const char *first64;} SDKQueryGuard;
static const SDKQueryGuard SDKQueries[]={
    {"SteamAPI_ISteamUser_BLoggedOn",0x61b0,"63186d26d43edee55b36af518059d61956a6af2e95ba40d22ee5422358104bb9"},
    {"SteamAPI_ISteamApps_BIsSubscribedApp",0x73a4,"cea0a6c06cff083f588e38fd17459c2c5d15513c7bfb4b5f70043e8cfabfc471"},
    {"SteamAPI_ISteamApps_GetAppBuildId",0x7470,"a4e7d3156f0d37e1d742af99255c4eca4c7f03b78c08c96f69b6681c5da0676b"}
};
static void *GuardSDKQuery(void *sdk,uintptr_t base,const SDKQueryGuard *guard) {
    void *function=dlsym(sdk,guard->name);Dl_info image={0};
    if ((uintptr_t)function!=base+guard->offset || !dladdr(function,&image) || (uintptr_t)image.dli_fbase!=base ||
        !Executable((uintptr_t)function) || ![MemoryHash((uintptr_t)function,64) isEqual:@(guard->first64)]) return NULL;
    return function;
}
static BOOL QueryProgress(NSMutableDictionary *queries,NSString *stage) {
    Fields(@{@"post_auth_sdk_queries":[queries copy]});return Save(stage,nil);
}
static void PostAuthSDKQueries(void *sdk,uintptr_t sdkBase,uintptr_t clientBase,void *engineUser,
    void *user,void *apps,BOOL(*cancelled)(void)) {
    NSMutableDictionary *queries=[@{@"status":@"not_run",@"app_id":@3009300,
        @"sdk_logged_on":@{@"status":@"not_run"},@"subscription":@{@"status":@"not_run"},
        @"app_build":@{@"status":@"not_run",@"availability":@"unknown",@"value":NSNull.null,
            @"freshness":@"not_measured",@"latest_build_claimed":@NO},
        @"identity_comparison":@{@"status":@"not_run",@"reason":@"not_requested_no_identity_values_recorded"},
        @"sdk_initialization_result_unchanged":@YES,@"network_request_initiated_by_toolkit":@NO} mutableCopy];
    if (!cancelled || cancelled()) {queries[@"status"]=@"not_run_cancelled";QueryProgress(queries,nil);return;}
    BOOL engineGuard=NO;BOOL engineLoggedOn=RealLoggedOn(clientBase,engineUser,&engineGuard);
    queries[@"actual_engine_logged_on_precondition"]=@(engineGuard && engineLoggedOn);
    if (!engineGuard || !engineLoggedOn) {queries[@"status"]=@"not_run_engine_logon_unavailable";QueryProgress(queries,nil);return;}
    void *functions[3]={NULL,NULL,NULL};NSMutableArray *guards=[NSMutableArray array];
    for (size_t i=0;i<3;i++) {
        functions[i]=GuardSDKQuery(sdk,sdkBase,&SDKQueries[i]);
        [guards addObject:@{@"export":@(SDKQueries[i].name),@"concrete_sdk_code_guard_passed":@(functions[i]!=NULL)}];
    }
    queries[@"export_guards"]=guards;
    if (!functions[0] || !functions[1] || !functions[2]) {queries[@"status"]=@"not_run_export_guard_failed";QueryProgress(queries,nil);return;}
    // Owned SDK flat ARM64 trampolines preserve x0=self (and w1=AppId for
    // subscription) and tail-dispatch User slot1 / Apps slots6 and23. Flat ABI:
    // bool BLoggedOn(void*); bool BIsSubscribedApp(void*,uint32_t);
    // int32_t GetAppBuildId(void*). No raw internal-client slot is called here.
    bool (*loggedOn)(void *)=(void *)functions[0];
    bool (*subscribed)(void *,uint32_t)=(void *)functions[1];
    int32_t (*buildID)(void *)=(void *)functions[2];
    @try {
        queries[@"status"]=@"in_progress";
        if (cancelled()) {queries[@"status"]=@"not_run_cancelled";QueryProgress(queries,nil);return;}
        queries[@"sdk_logged_on"]=@{@"status":@"call_pending"};
        if (!QueryProgress(queries,@"post_auth_original_sdk_BLoggedOn_pending")) {queries[@"status"]=@"failed_progress_write";return;}
        BOOL actualLoggedOn=loggedOn(user);
        queries[@"sdk_logged_on"]=@{@"status":@"returned",@"value":@(actualLoggedOn)};
        if (cancelled()) {queries[@"status"]=@"cancelled_after_partial_queries";QueryProgress(queries,nil);return;}
        queries[@"subscription"]=@{@"status":@"call_pending"};
        if (!QueryProgress(queries,@"post_auth_original_sdk_BIsSubscribedApp_pending")) {queries[@"status"]=@"failed_progress_write";return;}
        Fields(@{@"ownership_queried":@YES});
        BOOL actualSubscription=subscribed(apps,3009300);
        // A false return is an observed API answer; do not replace it with an
        // ownership, server-connectivity or license-cache interpretation.
        queries[@"subscription"]=@{@"status":@"returned",@"value":@(actualSubscription)};
        if (cancelled()) {queries[@"status"]=@"cancelled_after_partial_queries";QueryProgress(queries,nil);return;}
        queries[@"app_build"]=@{@"status":@"call_pending",@"availability":@"unknown",@"value":NSNull.null,
            @"freshness":@"not_measured",@"latest_build_claimed":@NO};
        if (!QueryProgress(queries,@"post_auth_original_sdk_GetAppBuildId_pending")) {queries[@"status"]=@"failed_progress_write";return;}
        int32_t actualBuild=buildID(apps);
        queries[@"app_build"]=@{@"status":@"returned",@"availability":actualBuild>0?@"reported_by_native_client":@"unknown",
            @"value":actualBuild>0?@(actualBuild):NSNull.null,@"freshness":@"not_measured",@"latest_build_claimed":@NO,
            @"nonpositive_return_observed":@(actualBuild<=0)};
        queries[@"status"]=@"completed";
    } @catch (__unused NSException *exception) {
        queries[@"status"]=@"failed_objective_c_exception";
    } @finally {
        QueryProgress(queries,@"post_auth_sdk_queries_observed");
    }
}

static BOOL GameRuntimeCwd(NSURL *documents) {
    char current[PATH_MAX],expected[PATH_MAX];
    NSURL *runtime=[documents URLByAppendingPathComponent:@"GameRuntime" isDirectory:YES];
    NSString *expectedPath=[documents.URLByResolvingSymlinksInPath.path stringByAppendingPathComponent:@"GameRuntime"];
    if (![runtime.URLByResolvingSymlinksInPath.path isEqual:expectedPath]) return NO;
    return realpath(".",current) && realpath(runtime.fileSystemRepresentation,expected) && !strcmp(current,expected);
}
static NSDictionary *RunIPC(void *client,void *loggedOnUser,BOOL afterLogon,BOOL prepareGame,BOOL(*cancelled)(void)) {
    if (NSThread.isMainThread) return @{@"status":@"failed",@"failure_code":@"background_serial_queue_required"};
    bool expected=false;
    if (!atomic_compare_exchange_strong(&Attempted,&expected,true)) return @{@"status":@"failed",@"failure_code":@"one_attempt_per_process_restart_required"};
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    Progress=[documents URLByAppendingPathComponent:prepareGame?@"steam-game-ipc-progress.json":@"steam-ipc-progress.json"];
    Report=[@{@"schema_version":@1,@"status":@"starting",@"stage":@"preconditions",
        @"scope":@"Genuine in-app Valve helper, app-local Mach service and original Steam SDK initialization; no login or game calls",
        @"authentication_attempted":@NO,@"ownership_queried":@NO,@"identity_values_recorded":@NO,
        @"post_auth_sdk_queries":@{@"status":@"not_run",@"reason":@"requires_real_engine_logon_original_sdk_success_and_interfaces"},
        @"original_sdk_context_init_replaced":@NO,@"sdk_init_called":@NO,@"helper_exited":@NO,
        @"process_restart_required":@YES,@"vendor_calls_interruptible":@NO,
        @"limitations":@[@"Mach service is app-local; no system launchd registration is claimed.",
            @"A sent registration message is not proof the helper accepted it; original SDK performs its own path query.",
            @"No login, account ownership or combined-game readiness follows from SDK initialization.",
            @"Helper thread/image remains alive until process termination; externally bound vendor calls."]} mutableCopy];
    if (!Save(@"preconditions",@"starting")) return Failure(@"progress_file_unwritable");
    NSArray *arguments=NSProcessInfo.processInfo.arguments;
    BOOL loginMode=[arguments containsObject:@"--tfm-steam-login"];
    BOOL playMode=TFMSteamCombinedLaunchRequested();
    BOOL allowedMode=prepareGame ? (playMode && afterLogon && !loginMode && ![arguments containsObject:@"--tfm-steam-sdk-probe"] && ![arguments containsObject:@"--tfm-start-steam-engine"]) :
        (!playMode && [arguments containsObject:@"--tfm-steam-sdk-probe"] && (afterLogon?loginMode:([arguments containsObject:@"--tfm-start-steam-engine"] && !loginMode)) && ![arguments containsObject:@"--tfm-run-main"]);
    if (!allowedMode)
        return Failure(@"explicit_isolated_sdk_probe_mode_required");
    if (afterLogon && (!cancelled || cancelled())) return Failure(@"post_logon_sdk_probe_cancelled_before_helper_or_sdk");
    Fields(@{@"sdk_probe_after_real_engine_logon_requested":@(afterLogon)});
    if (afterLogon) Fields(@{@"scope":@"Genuine original helper/SDK and read-only native login, subscription and build observations after separately approved engine login; no game calls",
        @"prior_fresh_qr_engine_login_required":@YES,@"authentication_performed_by_this_ipc_module":@NO});
    if (prepareGame) {
        BOOL cwd=GameRuntimeCwd(documents);
        Fields(@{@"scope":@"Prepare genuine helper/service/registration after native logon; original SDK initialization remains exclusively with the game wrapper",
            @"game_runtime_cwd_verified":@(cwd),@"cwd_changed_by_ipc":@NO,@"original_sdk_initialization_deferred_to_game":@YES});
        if (!cwd) return Failure(@"game_runtime_cwd_required_and_must_remain_fixed");
    }
    NSURL *frameworks=NSBundle.mainBundle.privateFrameworksURL;
    NSURL *clientURL=[frameworks URLByAppendingPathComponent:@"steamclient.dylib"];
    uintptr_t clientBase=ImageBase(clientURL);Dl_info factoryImage={0};void *factory=client?dlsym(client,"CreateInterface"):NULL;
    if (!factory || !dladdr(factory,&factoryImage) || !clientBase || (uintptr_t)factoryImage.dli_fbase!=clientBase) return Failure(@"validated_concrete_client_required");
    if (afterLogon) {
        BOOL guarded=NO;
        if (!Save(@"actual_engine_BLoggedOn_precondition_pending",@"observing")) return Failure(@"progress_write_failed");
        BOOL loggedOn=RealLoggedOn(clientBase,loggedOnUser,&guarded);
        Fields(@{@"engine_logged_on_query_guard_passed":@(guarded),@"actual_engine_logged_on_before_helper":@(loggedOn)});
        if (!guarded || !loggedOn) return Failure(@"actual_guarded_engine_logon_required_before_helper_or_sdk");
    }
    NSData *profileBytes=[NSData dataWithContentsOfURL:[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"SteamIPCProfile.json"]];
    NSDictionary *profile=profileBytes?[NSJSONSerialization JSONObjectWithData:profileBytes options:0 error:NULL]:nil;
    NSDictionary *hp=profile[@"helper"],*sp=profile[@"sdk"];
    if ([profile[@"schema_version"] intValue]!=1 || ![hp[@"original_arm64_sha256"] isEqual:@"c0093a41b685bd633b585e9ca1cbe40c7fa9b43397fb6e254019953b1a99936b"] || [hp[@"original_lc_main_entryoff"] unsignedLongLongValue]!=6888 || ![sp[@"original_universal_sha256"] isEqual:@"363ab50ce9bf4680d8ddb8c6142e566854803f831769fab0428867b9994d0520"])
        return Failure(@"bundled_pinned_metadata_profile_missing_or_mismatched");
    // Enable before dlopen: any original helper initializer sees the same state.
    pthread_mutex_lock(&ServiceLock);Enabled=YES;pthread_mutex_unlock(&ServiceLock);
    NSURL *helperURL=[frameworks URLByAppendingPathComponent:@"TFMSteamIPCHelper.dylib"];
    NSURL *sdkURL=[frameworks URLByAppendingPathComponent:prepareGame?@"TFMOriginalSteamAPI.dylib":@"libsteam_api.dylib"];
    Fields(@{@"original_sdk_runtime_image":sdkURL.lastPathComponent});
    if (!Save(@"load_owned_helper_and_sdk",@"starting")) return Failure(@"progress_write_failed");
    void *helper=dlopen(helperURL.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    void *sdk=dlopen(sdkURL.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    if (!helper || !sdk) return Failure(@"owned_helper_or_sdk_load_failed");
    Fields(@{@"generic_handle_lookup_images":@{@"helper_check_in":SymbolImage(dlsym(helper,"bootstrap_check_in")),
        @"helper_exit":SymbolImage(dlsym(helper,"exit")),@"sdk_look_up":SymbolImage(dlsym(sdk,"bootstrap_look_up"))},
        @"generic_handle_lookup_is_binding_proof":@NO});
    NSDictionary *helperBinding=Binding(helperURL,@"_bootstrap_check_in",@"TFMSteamLibSystem.dylib",TFMSteamBootstrapCheckIn,YES);
    NSDictionary *exitBinding=Binding(helperURL,@"_exit",@"TFMSteamLibSystem.dylib",TFMSteamIPCExit,YES);
    NSDictionary *signalBinding=Binding(helperURL,@"_signal",@"TFMSteamLibSystem.dylib",TFMSteamIPCSignal,YES);
    NSDictionary *sdkBinding=SDKBinding(sdkURL,TFMSteamBootstrapLookUp,YES);
    BOOL helperBound=[helperBinding[@"verified"] boolValue] && [exitBinding[@"verified"] boolValue] && [signalBinding[@"verified"] boolValue],sdkBound=[sdkBinding[@"verified"] boolValue];
    Fields(@{@"bindings_before_vendor_calls":@[helperBinding,exitBinding,signalBinding,sdkBinding],
        @"helper_import_boundary_verified":@(helperBound),@"sdk_import_boundary_verified":@(sdkBound)});
    if (!helperBound || !sdkBound) return Failure(@"shared_ipc_concrete_ordinal_provider_or_import_slot_guard_failed");
    uintptr_t helperBase=ImageBase(helperURL),sdkBase=ImageBase(sdkURL),helperText=0,sdkText=0;
    size_t helperTextSize=0,sdkTextSize=0;NSString *helperUUID=nil,*sdkUUID=nil;
    if (!ImageMetadata(helperBase,&helperUUID,&helperText,&helperTextSize) || ![helperUUID isEqual:@"e4d6996719f233189427f21f8eda03e1"] ||
        ![MemoryHash(helperText,helperTextSize) isEqual:@"7fa3e7c65fcec87df8a72d7d5c0a0400a8e394fb74c294268019f70270d48df2"] ||
        !ImageMetadata(sdkBase,&sdkUUID,&sdkText,&sdkTextSize) || ![sdkUUID isEqual:@"fca0302280d73c019d1242b887a94e65"])
        return Failure(@"helper_or_sdk_uuid_text_guard_failed");
    uintptr_t entry=helperBase+[hp[@"original_lc_main_entryoff"] unsignedLongLongValue];
    uintptr_t initialize=(uintptr_t)dlsym(sdk,"SteamInternal_SteamAPI_Init");
    if (entry<helperText || entry+64>helperText+helperTextSize || !Executable(entry) ||
        ![MemoryHash(entry,64) isEqual:@"6c78a806a3358e36196a96af00c740d71ae8e23df5a5feffa8aa715b30ec4883"] ||
        initialize!=sdkBase+0x38c8 || !Executable(initialize) || ![MemoryHash(initialize,64) isEqual:@"19fdea73257a51133d7751403b41b6b691ba77e3ea8da8a8e06390f4023ffea1"])
        return Failure(@"derived_helper_entry_or_sdk_init_code_guard_failed");
    NSDictionary *signalProfile=hp[@"process_sigterm_registration"];
    BOOL signalGuard=[signalProfile[@"signal"] intValue]==SIGTERM &&
        [signalProfile[@"handler_offset"] unsignedLongLongValue]==0x1acc &&
        [signalProfile[@"callsite_offset"] unsignedLongLongValue]==0x1b68 &&
        [signalProfile[@"return_offset"] unsignedLongLongValue]==0x1b6c &&
        helperBase+0x1acc>=helperText && helperBase+0x1b6c<=helperText+helperTextSize &&
        [signalProfile[@"registration_first16_sha256"] isEqual:@"4da776cb584b1fa6e21600a39c1bc0736dc02288fae754e3f7cd79a4c3a13d1c"] &&
        [signalProfile[@"handler_first28_sha256"] isEqual:@"e8333f9dd767f135db0782ae102a7968361978c83a58481f476ac75addc050d9"] &&
        [MemoryHash(helperBase+0x1b5c,16) isEqual:signalProfile[@"registration_first16_sha256"]] &&
        [MemoryHash(helperBase+0x1acc,28) isEqual:signalProfile[@"handler_first28_sha256"]];
    if (!signalGuard) return Failure(@"helper_process_signal_registration_guard_failed");
    atomic_store_explicit(&HelperSignalBase,helperBase,memory_order_relaxed);
    atomic_store_explicit(&HelperSignalScopeVerified,true,memory_order_release);
    Fields(@{@"helper_process_signal_policy":@"Reject only the pinned embedded-helper SIGTERM registration with SIG_ERR/ENOTSUP; preserve host disposition",
        @"helper_process_signal_guard_passed":@YES});
    Fields(@{@"original_helper_lc_main_derived_entry_guard_passed":@YES,@"sdk_init_guard_passed":@YES});
    if (afterLogon && cancelled()) return Failure(@"post_logon_sdk_probe_cancelled_before_helper_or_sdk");
    if (!Save(@"start_owned_helper_thread",@"starting")) return Failure(@"progress_write_failed");
    pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED);
    pthread_t thread;int threadResult=pthread_create(&thread,&attr,HelperMain,(void *)entry);pthread_attr_destroy(&attr);
    if (threadResult) return Failure(@"helper_thread_creation_failed");
    NSTimeInterval readyDeadline=NSProcessInfo.processInfo.systemUptime+2;
    while (![TFMSteamIPCStatus()[@"service_ready"] boolValue] && NSProcessInfo.processInfo.systemUptime<readyDeadline && !(afterLogon && cancelled())) usleep(10000);
    if (afterLogon && cancelled()) return Failure(@"post_logon_sdk_probe_cancelled_before_sdk");
    if (![TFMSteamIPCStatus()[@"service_ready"] boolValue]) return Failure(@"genuine_helper_did_not_check_in");
    NSDictionary *afterHelper=Binding(helperURL,@"_bootstrap_check_in",@"TFMSteamLibSystem.dylib",TFMSteamBootstrapCheckIn,NO);
    NSDictionary *afterSignal=Binding(helperURL,@"_signal",@"TFMSteamLibSystem.dylib",TFMSteamIPCSignal,NO);
    Fields(@{@"helper_binding_after_genuine_check_in":afterHelper,@"helper_signal_binding_after_check_in":afterSignal,
        @"helper_signal_isolation":TFMSteamIPCStatus()});
    if (![afterHelper[@"verified"] boolValue]) return Failure(@"helper_called_check_in_but_import_slot_not_expected_shared_definition");
    if (![afterSignal[@"verified"] boolValue] || atomic_load_explicit(&HelperSIGTERMRegistrationsDeclined,memory_order_relaxed)!=1)
        return Failure(@"helper_signal_registration_not_isolated_by_expected_shared_definition");
    BOOL referenceTest=ProbeLookupReferences();Fields(@{@"lookup_rights_lifetime_test_passed":@(referenceTest)});
    if (!referenceTest) return Failure(@"lookup_send_right_reference_test_failed");
    mach_port_t service=MACH_PORT_NULL;
    kern_return_t lookup=TFMSteamBootstrapLookUp(MACH_PORT_NULL,ServiceName,&service);
    struct {mach_msg_header_t header;uint32_t operation,pid;char path[512];} request={0};
    const char *path=clientURL.fileSystemRepresentation;
    if (strlen(path)>=sizeof request.path) {if (MACH_PORT_VALID(service)) mach_port_deallocate(mach_task_self(),service);return Failure(@"concrete_client_path_exceeds_helper_protocol_capacity");}
    request.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0);request.header.msgh_size=sizeof request;
    request.header.msgh_remote_port=service;request.header.msgh_id=104;request.operation=13;request.pid=(uint32_t)getpid();strlcpy(request.path,path,sizeof request.path);
    if (!Save(@"send_genuine_helper_registration",@"starting")) {if (MACH_PORT_VALID(service)) mach_port_deallocate(mach_task_self(),service);return Failure(@"progress_write_failed");}
    kern_return_t sent=lookup==KERN_SUCCESS?mach_msg(&request.header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof request,0,MACH_PORT_NULL,2000,MACH_PORT_NULL):lookup;
    if (MACH_PORT_VALID(service)) mach_port_deallocate(mach_task_self(),service);
    Fields(@{@"registration_send_status":@(sent),@"registration_message_sent":@(sent==KERN_SUCCESS)});
    if (sent!=KERN_SUCCESS) return Failure(@"helper_registration_message_send_failed");
    if (prepareGame) {
        if (cancelled()) return Failure(@"game_helper_preparation_cancelled");
        BOOL guarded=NO;BOOL loggedOn=RealLoggedOn(clientBase,loggedOnUser,&guarded);
        if (cancelled()) return Failure(@"game_helper_preparation_cancelled_after_logon_query");
        BOOL ready=[TFMSteamIPCStatus()[@"service_ready"] boolValue];
        Fields(@{@"actual_engine_logged_on_at_helper_ready":@(guarded && loggedOn),@"helper_service_ready":@(ready),
            @"verified_logon_uptime":@(NSProcessInfo.processInfo.systemUptime),@"post_auth_sdk_queries":@{@"status":@"not_run",@"reason":@"game_owns_original_sdk_initialization"}});
        if (!guarded || !loggedOn || !ready || !GameRuntimeCwd(documents)) return Failure(@"game_helper_final_logon_service_or_cwd_precondition_failed");
        if (!Save(@"game_helper_ready_original_sdk_not_called",@"game_ipc_helper_ready_original_sdk_not_called")) return Failure(@"progress_write_failed_at_game_helper_ready");
        if (cancelled()) return Failure(@"game_helper_preparation_cancelled_before_ready");
        return Snapshot();
    }
    if (setenv("SteamAppId","3009300",1) || setenv("SteamGameId","3009300",1)) return Failure(@"app_id_environment_failed");
    // Original SDK consumes a double-NUL-terminated list of interface versions.
    // This diagnostic deliberately requests only the three interfaces below;
    // future game forwarding must preserve the game's complete original list.
    static const char versions[]="SteamUser023\0SteamUtils010\0STEAMAPPS_INTERFACE_VERSION008\0";
    void *knownInterface=dlsym(client,"Steam_IsKnownInterface");
    void *notifyMissing=dlsym(client,"Steam_NotifyMissingInterface");
    // These are export-presence observations, not interface/factory calls.
    // The pinned SDK skips its version-list check if the former is absent.
    Fields(@{@"requested_public_interfaces":@[@"SteamUser023",@"SteamUtils010",@"STEAMAPPS_INTERFACE_VERSION008"],
        @"client_known_interface_checker_export_present":@(knownInterface!=NULL),
        @"client_missing_interface_notifier_export_present":@(notifyMissing!=NULL),
        @"additional_client_factory_or_interface_queries_called":@NO});
    char error[1024]={0};
    if (afterLogon) {
        if (cancelled()) return Failure(@"post_logon_sdk_probe_cancelled_before_sdk");
        BOOL guarded=NO;BOOL loggedOn=RealLoggedOn(clientBase,loggedOnUser,&guarded);
        if (cancelled()) return Failure(@"post_logon_sdk_probe_cancelled_after_logon_query");
        Fields(@{@"actual_engine_logged_on_immediately_before_sdk":@(guarded && loggedOn)});
        if (!guarded || !loggedOn) return Failure(@"engine_logon_lost_before_original_sdk_initialization");
    }
    if (!Save(@"original_SteamInternal_SteamAPI_Init_pending",@"observing")) return Failure(@"progress_write_failed");
    Fields(@{@"sdk_init_called":@YES});Save(nil,nil);
    if (afterLogon && cancelled()) {
        Fields(@{@"sdk_init_called":@NO});
        return Failure(@"post_logon_sdk_probe_cancelled_immediately_before_sdk");
    }
    int result=((int(*)(const char *,char *))initialize)(versions,error);error[sizeof error-1]=0;
    NSDictionary *afterSDK=SDKBinding(sdkURL,TFMSteamBootstrapLookUp,NO);
    Fields(@{@"sdk_init_result":@(result),@"sdk_init_success":@(result==0),
        @"sdk_error_present":@(error[0]!=0),@"sdk_error_category":ErrorCategory(error),@"ipc_status":TFMSteamIPCStatus(),
        @"sdk_error_exact_public_interface":ExactErrorInterface(error),
        @"sdk_binding_after_genuine_initialization":afterSDK});
    if (result==1 && [ErrorCategory(error) isEqual:@"native_steam_utils_app_id_zero"])
        Fields(@{@"failure_stage_inferred_from_pinned_sdk_code":@"SteamUtils010_GetAppID_returned_zero",
            @"inference_limitation":@"The native app ID is zero; this does not establish a login, subscription or ownership failure."});
    if (result==3 && !knownInterface && [ExactErrorInterface(error) isEqual:@"SteamUser023"])
        Fields(@{@"failure_stage_inferred_from_pinned_sdk_code":@"GetISteamUser_SteamUser023_returned_null",
            @"version_list_validation_skipped_by_original_sdk":@YES,
            @"inference_limitation":@"Public user unavailable does not identify why; genuine engine login and licensing remain separate unproven gates."});
    if (![afterSDK[@"verified"] boolValue]) return Failure(@"sdk_initialization_returned_but_lookup_slot_not_expected_shared_definition");
    if (result!=0) return Failure(@"original_sdk_initialization_returned_failure");
    // Do not manufacture factory objects, pipe/user handles, context storage,
    // SteamID, ownership or success. The original SDK owns those objects.
    void *(*getUser)(void)=dlsym(sdk,"SteamAPI_SteamUser_v023");
    void *(*getApps)(void)=dlsym(sdk,"SteamAPI_SteamApps_v008");
    void *user=getUser?getUser():NULL,*apps=getApps?getApps():NULL;
    Fields(@{@"sdk_user023_interface_present":@(user!=NULL),@"sdk_apps008_interface_present":@(apps!=NULL)});
    if (!user || !apps) return Failure(@"sdk_success_but_required_interface_unavailable");
    if (afterLogon) PostAuthSDKQueries(sdk,sdkBase,clientBase,loggedOnUser,user,apps,cancelled);
    else Fields(@{@"post_auth_sdk_queries":@{@"status":@"not_run",@"reason":@"unauthenticated_sdk_probe"}});
    NSString *status=afterLogon?@"sdk_initialized_after_genuine_engine_logon":@"sdk_initialized_no_login_or_ownership_claim";
    if (!Save(@"completed_genuine_sdk_initialization",status)) return Failure(@"progress_write_failed_at_completion");
    return Snapshot();
}
NSDictionary *TFMSteamIPCProbe(void *client) {return RunIPC(client,NULL,NO,NO,NULL);}
NSDictionary *TFMSteamIPCProbeAfterLogon(void *client,void *user,BOOL(*cancelled)(void)) {return RunIPC(client,user,YES,NO,cancelled);}
NSDictionary *TFMSteamIPCPrepareForGame(void *client,void *user,BOOL(*cancelled)(void)) {return RunIPC(client,user,YES,YES,cancelled);}
