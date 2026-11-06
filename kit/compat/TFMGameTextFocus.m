#import "TFMGameTextFocus.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <string.h>

static const uintptr_t AllowedSetter=0x294a950,IvarOffsetStorage=0x4598730;
static const size_t AllowedWithinIvars=0xc9;
static uintptr_t VerifiedGameBase,VerifiedTextStart;
static size_t VerifiedTextSize;

static NSDictionary *Unavailable(NSString *reason) {
    return @{@"available":@NO,@"status":reason,@"native_state_read_only":@YES,
        @"text_field_focus_proven":@NO,@"candidate_area_available":@NO};
}
static BOOL Read(uintptr_t address,void *output,size_t count) {
    vm_size_t copied=0;
    return address && output && count && count<=512 && address<=UINTPTR_MAX-count &&
        vm_read_overwrite(mach_task_self(),address,count,(vm_address_t)output,&copied)==KERN_SUCCESS && copied==count;
}
static BOOL SetterHash(uintptr_t base) {
    unsigned char bytes[216],digest[CC_SHA256_DIGEST_LENGTH];char hex[65];
    if (!Read(base+AllowedSetter,bytes,sizeof bytes)) return NO;
    CC_SHA256(bytes,(CC_LONG)sizeof bytes,digest);
    for (size_t i=0;i<sizeof digest;i++) snprintf(hex+2*i,3,"%02x",digest[i]);
    return !strcmp(hex,"13d7f8a88fd79e0eb0416d327c35bb2ec1f57f1518bb1261d84b1f79c7ead69d");
}
static BOOL Profile(uintptr_t base) {
    static const unsigned char expectedUUID[16]={0xd1,0xee,0x0f,0xfa,0xe0,0x9c,0x3f,0x50,0x91,0xf7,0xa3,0xee,0x97,0x5c,0x02,0xae};
    if (VerifiedGameBase==base) return YES;
    struct mach_header_64 header={0};
    if (!Read(base,&header,sizeof header) || header.magic!=MH_MAGIC_64 || header.cputype!=CPU_TYPE_ARM64 || header.filetype!=MH_DYLIB ||
        !header.ncmds || header.ncmds>1024 || !header.sizeofcmds || header.sizeofcmds>1024*1024 || base>UINTPTR_MAX-sizeof header-header.sizeofcmds) return NO;
    uintptr_t cursor=base+sizeof header,end=cursor+header.sizeofcmds;
    BOOL uuid=NO,text=NO,section=NO,offsetStorage=NO;uint64_t textVM=0,sectionVM=0,sectionSize=0;
    for (uint32_t i=0;i<header.ncmds;i++) {
        struct load_command command={0};
        if (cursor>end || end-cursor<sizeof command || !Read(cursor,&command,sizeof command) || command.cmdsize<sizeof command || command.cmdsize>end-cursor) return NO;
        if (command.cmd==LC_UUID) {
            struct uuid_command value={0};
            if (uuid || command.cmdsize<sizeof value || !Read(cursor,&value,sizeof value) || memcmp(value.uuid,expectedUUID,16)) return NO;
            uuid=YES;
        } else if (command.cmd==LC_SEGMENT_64) {
            struct segment_command_64 segment={0};
            if (command.cmdsize<sizeof segment || !Read(cursor,&segment,sizeof segment) || segment.nsects>(command.cmdsize-sizeof segment)/sizeof(struct section_64)) return NO;
            if (!strncmp(segment.segname,"__TEXT",16)) {
                if (text) return NO;text=YES;textVM=segment.vmaddr;
                for (uint32_t j=0;j<segment.nsects;j++) {
                    struct section_64 value={0};
                    if (!Read(cursor+sizeof segment+j*sizeof value,&value,sizeof value)) return NO;
                    if (!strncmp(value.segname,"__TEXT",16) && !strncmp(value.sectname,"__text",16)) {
                        if (section) return NO;section=YES;sectionVM=value.addr;sectionSize=value.size;
                    }
                }
            }
            // This exact original image has __TEXT vmaddr 0x100000000.
            // Confirm the dynamic ivar-offset storage belongs to a data region.
            if ((!strncmp(segment.segname,"__DATA",6)) && segment.vmaddr>=0x100000000ULL && segment.vmsize>=sizeof(uint64_t)) {
                uint64_t relative=segment.vmaddr-0x100000000ULL;
                if (IvarOffsetStorage>=relative && IvarOffsetStorage-relative<=segment.vmsize-sizeof(uint64_t)) offsetStorage=YES;
            }
        }
        cursor+=command.cmdsize;
    }
    if (!uuid || !text || !section || !offsetStorage || textVM!=0x100000000ULL || sectionVM<textVM || sectionSize>SIZE_MAX ||
        sectionVM-textVM>UINTPTR_MAX-base || sectionSize>UINTPTR_MAX-(base+(uintptr_t)(sectionVM-textVM))) return NO;
    uintptr_t start=base+(uintptr_t)(sectionVM-textVM);
    if (sectionSize<216 || base+AllowedSetter<start || base+AllowedSetter-start>sectionSize-216 || !SetterHash(base)) return NO;
    VerifiedGameBase=base;VerifiedTextStart=start;VerifiedTextSize=(size_t)sectionSize;return YES;
}
static BOOL OwnedMethod(Class type,const char *selector,uintptr_t *base) {
    Method method=class_getInstanceMethod(type,sel_registerName(selector));
    IMP implementation=method?method_getImplementation(method):NULL;Dl_info info={0};
    if (!implementation || !dladdr((void *)implementation,&info) || !info.dli_fbase || !info.dli_fname) return NO;
    char actual[PATH_MAX],expected[PATH_MAX];
    NSURL *path=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"TeamfightManager2.dylib"];
    if (!realpath(info.dli_fname,actual) || !realpath(path.fileSystemRepresentation,expected) || strcmp(actual,expected)) return NO;
    uintptr_t owner=(uintptr_t)info.dli_fbase;
    if ((*base && *base!=owner) || !Profile(owner)) return NO;
    uintptr_t code=(uintptr_t)implementation;
    if (code<VerifiedTextStart || code-VerifiedTextStart>=VerifiedTextSize) return NO;
    *base=owner;return YES;
}
static NSDictionary *ReadState(const void *object,size_t instanceSize,size_t superclassSize,uint64_t offset,BOOL verified) {
    if (!verified) return Unavailable(@"game_profile_not_verified");
    if (!object || !superclassSize || superclassSize>instanceSize || instanceSize>1024*1024 || offset<superclassSize || offset%8 ||
        offset>instanceSize || instanceSize-(size_t)offset<=AllowedWithinIvars || (uintptr_t)object>UINTPTR_MAX-offset-AllowedWithinIvars)
        return Unavailable(@"native_ivar_bounds_invalid");
    unsigned char allowed=0;
    if (!Read((uintptr_t)object+(uintptr_t)offset+AllowedWithinIvars,&allowed,1)) return Unavailable(@"native_ime_flag_unreadable");
    if (allowed>1) return Unavailable(@"native_ime_flag_not_boolean");
    return @{@"available":@YES,@"status":@"verified_read_only_ime_state",@"profile_verified":@YES,
        @"ime_allowed":@((BOOL)allowed),@"native_state_read_only":@YES,@"text_field_focus_proven":@NO,
        @"signal":@"engine_input_mode_via_winit_ime_allowed",@"candidate_area_available":@NO,
        @"candidate_area_reason":@"native_cursor_field_offsets_not_audited"};
}
NSDictionary *TFMGameTextFocusSnapshot(id view) {
    @autoreleasepool {
        if (!NSThread.isMainThread) return Unavailable(@"main_thread_required");
        if (!view) return Unavailable(@"original_winit_view_required");
        Class type=object_getClass(view),superclass=class_getSuperclass(type);
        if (!type || strcmp(class_getName(type),"WinitView") || !superclass || strcmp(class_getName(superclass),"NSView"))
            return Unavailable(@"original_winit_view_class_required");
        uintptr_t base=0;
        if (!OwnedMethod(type,"firstRectForCharacterRange:actualRange:",&base) ||
            !OwnedMethod(type,"insertText:replacementRange:",&base) ||
            !OwnedMethod(type,"setMarkedText:selectedRange:replacementRange:",&base)) return Unavailable(@"native_view_method_profile_not_verified");
        uint64_t offset=0;
        if (!Read(base+IvarOffsetStorage,&offset,sizeof offset)) return Unavailable(@"native_ivar_offset_unreadable");
        return ReadState((__bridge const void *)view,class_getInstanceSize(type),class_getInstanceSize(superclass),offset,YES);
    }
}
static BOOL ValidSnapshot(NSDictionary *snapshot,BOOL *allowed) {
    if (![snapshot isKindOfClass:NSDictionary.class] || ![snapshot[@"status"] isEqual:@"verified_read_only_ime_state"] ||
        ![snapshot[@"available"] isEqual:@YES] || ![snapshot[@"profile_verified"] isEqual:@YES] ||
        ![snapshot[@"ime_allowed"] isKindOfClass:NSNumber.class]) return NO;
    NSNumber *value=snapshot[@"ime_allowed"];
    if (![value isEqual:@NO] && ![value isEqual:@YES]) return NO;
    *allowed=value.boolValue;return YES;
}
BOOL TFMGameTextFocusHasTapAssociatedIMEEnable(NSDictionary *before,NSDictionary *after,BOOL sameView,BOOL recentTap) {
    BOOL wasAllowed=NO,isAllowed=NO;
    return sameView && recentTap && ValidSnapshot(before,&wasAllowed) && ValidSnapshot(after,&isAllowed) && !wasAllowed && isAllowed;
}
#ifdef TFM_GAME_TEXT_FOCUS_TESTING
NSDictionary *TFMGameTextFocusTestRead(const void *bytes,size_t instanceSize,size_t superclassSize,uint64_t offset,BOOL verified) {
    return ReadState(bytes,instanceSize,superclassSize,offset,verified);
}
#endif
