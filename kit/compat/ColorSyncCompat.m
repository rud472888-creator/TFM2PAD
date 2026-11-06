// Original bounded ColorSync boundary for winit's monitor matching.
// These UUIDs identify this adapter's connected logical displays for the current
// process only. They are random CFUUIDs, never a hardware UUID, EDID or serial.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef int32_t (*TFMActiveDisplayList)(uint32_t,uint32_t *,uint32_t *);
static void *TFMGraphicsHandle;
static TFMActiveDisplayList TFMActiveDisplays;
static CFMutableDictionaryRef TFMLogicalDisplayUUIDs;

static BOOL TFMDisplayConnected(uint32_t display) {
    if (!display || !NSThread.isMainThread) return NO;
    if (!TFMActiveDisplays) {
        NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TFMCoreGraphics.dylib"];
        // Resolve the concrete adapter, never the process-wide symbol namespace.
        TFMGraphicsHandle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        TFMActiveDisplays=TFMGraphicsHandle?dlsym(TFMGraphicsHandle,"CGGetActiveDisplayList"):NULL;
        if (!TFMActiveDisplays) return NO;
    }
    uint32_t count=0;
    if (TFMActiveDisplays(0,NULL,&count)!=0 || !count || count>1024) return NO;
    uint32_t *displays=calloc(count,sizeof(*displays));
    if (!displays) return NO;
    uint32_t actual=0;
    int32_t result=TFMActiveDisplays(count,displays,&actual);
    BOOL found=NO;
    if (!result && actual<=count)
        for (uint32_t index=0;index<actual;index++) if (displays[index]==display) { found=YES;break; }
    free(displays);return found;
}

CFUUIDRef TFMDisplayCreateUUIDFromDisplayID(uint32_t display) __asm__("_CGDisplayCreateUUIDFromDisplayID");
CFUUIDRef TFMDisplayCreateUUIDFromDisplayID(uint32_t display) {
    if (!TFMDisplayConnected(display)) {
        fprintf(stderr,"TFM_COLORSYNC_UUID unavailable display=%u main_thread=%d\n",display,NSThread.isMainThread);return NULL;
    }
    if (!TFMLogicalDisplayUUIDs)
        TFMLogicalDisplayUUIDs=CFDictionaryCreateMutable(kCFAllocatorDefault,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    if (!TFMLogicalDisplayUUIDs) return NULL;
    NSNumber *key=@(display);
    CFUUIDRef uuid=(CFUUIDRef)CFDictionaryGetValue(TFMLogicalDisplayUUIDs,(__bridge const void *)key);
    if (!uuid) {
        CFUUIDRef created=CFUUIDCreate(kCFAllocatorDefault);
        if (!created) return NULL;
        CFDictionarySetValue(TFMLogicalDisplayUUIDs,(__bridge const void *)key,created);
        CFRelease(created); // The process-lifetime dictionary owns its reference.
        uuid=(CFUUIDRef)CFDictionaryGetValue(TFMLogicalDisplayUUIDs,(__bridge const void *)key);
        fprintf(stderr,"TFM_COLORSYNC_UUID created process_local_identity=1 display=%u hardware_identity=0\n",display);
    }
    // Create-rule ownership for every caller. The cache also preserves object
    // identity for winit's pointer comparison, without leaking a hardware ID.
    return uuid?(CFUUIDRef)CFRetain(uuid):NULL;
}
