// Original bounded CoreVideo monitor-query adapter. No callback, timer, start or
// display-mode operation is implemented or claimed. winit v0.30.5 monitor.rs
// explicitly accepts kCVTimeIsIndefinite and returns unknown refresh (None).
#import "CoreVideoCompat.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

_Static_assert(sizeof(TFMCVTime)==16,"CVTime must occupy 16 bytes on ARM64");
_Static_assert(offsetof(TFMCVTime,timeScale)==8,"CVTime timeScale ABI");
_Static_assert(offsetof(TFMCVTime,flags)==12,"CVTime flags ABI");

enum { TFMCVSuccess=0,TFMCVError=-6660,TFMCVInvalidArgument=-6661,TFMCVAllocationFailed=-6662 };
struct TFMCVDisplayLink { uint32_t display; };
typedef int32_t (*TFMActiveDisplayList)(uint32_t,uint32_t *,uint32_t *);
static void *TFMCVGraphics;
static TFMActiveDisplayList TFMCVActiveDisplays;
static NSMutableSet<NSValue *> *TFMCVLiveLinks;
static NSLock *TFMCVRegistryLock;

static void TFMCVInitializeRegistry(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{TFMCVLiveLinks=[NSMutableSet set];TFMCVRegistryLock=[NSLock new];});
}
static BOOL TFMCVDisplayConnected(uint32_t display) {
    // The backing UIKit display inventory is main-thread-only. Once created,
    // this immutable query handle can be inspected/released on another thread.
    if (!NSThread.isMainThread || !display) return NO;
    if (!TFMCVActiveDisplays) {
        NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TFMCoreGraphics.dylib"];
        TFMCVGraphics=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        TFMCVActiveDisplays=TFMCVGraphics?dlsym(TFMCVGraphics,"CGGetActiveDisplayList"):NULL;
        if (!TFMCVActiveDisplays) return NO;
    }
    uint32_t count=0;
    if (TFMCVActiveDisplays(0,NULL,&count)!=0 || !count || count>1024) return NO;
    uint32_t *displays=calloc(count,sizeof(*displays));if (!displays) return NO;
    uint32_t actual=0;int32_t result=TFMCVActiveDisplays(count,displays,&actual);BOOL found=NO;
    if (!result && actual<=count)
        for (uint32_t i=0;i<actual;i++) if (displays[i]==display) { found=YES;break; }
    free(displays);return found;
}

int32_t TFMCVDisplayLinkCreateWithCGDisplay(uint32_t display,TFMCVDisplayLinkRef *outLink) {
    if (!outLink) return TFMCVInvalidArgument;
    *outLink=NULL;
    if (!NSThread.isMainThread || !TFMCVDisplayConnected(display)) return TFMCVInvalidArgument;
    TFMCVInitializeRegistry();
    TFMCVDisplayLinkRef link=calloc(1,sizeof(*link));if (!link) return TFMCVAllocationFailed;
    link->display=display;
    [TFMCVRegistryLock lock];[TFMCVLiveLinks addObject:[NSValue valueWithPointer:link]];[TFMCVRegistryLock unlock];
    *outLink=link; // One owned reference, balanced by CVDisplayLinkRelease.
    fprintf(stderr,"TFM_COREVIDEO_LINK_CREATED display=%u nominal_period=unknown timer_started=0\n",display);
    return TFMCVSuccess;
}
TFMCVTime TFMCVDisplayLinkGetNominalOutputVideoRefreshPeriod(TFMCVDisplayLinkRef link) {
    // Neither maximumFramesPerSecond nor a single variable CADisplayLink sample
    // establishes a fixed nominal ProMotion period. Preserve this uncertainty.
    // In particular, do not manufacture 1/60 or 1/120 seconds or divide by zero.
    const TFMCVTime indefinite={0,0,TFMCVTimeIsIndefinite};
    if (!link) return indefinite;
    TFMCVInitializeRegistry();[TFMCVRegistryLock lock];
    BOOL valid=[TFMCVLiveLinks containsObject:[NSValue valueWithPointer:link]];
    [TFMCVRegistryLock unlock];
    fprintf(stderr,"TFM_COREVIDEO_NOMINAL_INTERVAL valid_link=%d indefinite=1 fixed_refresh_claimed=0\n",valid);
    return indefinite;
}
void TFMCVDisplayLinkRelease(TFMCVDisplayLinkRef link) {
    if (!link) return;
    TFMCVInitializeRegistry();[TFMCVRegistryLock lock];
    NSValue *key=[NSValue valueWithPointer:link];BOOL valid=[TFMCVLiveLinks containsObject:key];
    if (valid) { [TFMCVLiveLinks removeObject:key];free(link); }
    [TFMCVRegistryLock unlock];
    if (!valid) fprintf(stderr,"TFM_COREVIDEO_RELEASE unknown_link=1\n");
}
