// TFM2 winit startup bridge. Selectively adapted from MIT AgePad's UIKit
// window/screen/event object models; see TFMAppKit-NOTICE.md.
#import "TFMAppKit.h"
#import "TFMGameTextFocus.h"
#import <QuartzCore/QuartzCore.h>
#import <GameController/GameController.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>

// Compatibility feature gate consumed by winit, not the host OS's version.
// We advertise the 10.12 baseline only. No full AppKit implementation is claimed.
double NSAppKitVersionNumber = 1504.0;
NSString *const NSAppearanceNameAqua = @"NSAppearanceNameAqua";
NSString *const NSDeviceRGBColorSpace = @"NSDeviceRGBColorSpace";
NSString *const NSFilenamesPboardType = @"NSFilenamesPboardType";
NSString *const NSPasteboardTypeString = @"public.utf8-plain-text";
NSString *const NSViewFrameDidChangeNotification = @"NSViewFrameDidChangeNotification";
static NSString *const TFMDarkAqua = @"NSAppearanceNameDarkAqua";
static UIWindow *TFMHostWindow;
static NSUInteger TFMWindowSequence = 1, TFMTrackingSequence = 1;
static const NSUInteger TFMFullScreenStyleMask = 1UL<<14;
static __weak id TFMKeyWindow, TFMMainWindow;
static NSHashTable *TFMWindows;
static NSUInteger TFMRunInvocationCount;
static void TFMRecordProgress(NSString *milestone);
static uint64_t TFMDirectTouchPostedWheelEvents(void);
static void TFMRefreshCursorRegions(void);
static void TFMWriteDiagnostic(NSString *filename,NSDictionary *fields);
static uint64_t TFMTouchDownCount,TFMTouchDragCount,TFMTouchUpCount,TFMTouchCancelCount,TFMTouchDispatchCount,TFMTouchSuppressedCount;
static uint64_t TFMRawTouchBeganEntries,TFMTouchMissingOwner,TFMIndirectTouchesIgnored;
static uint64_t TFMMouseMovementCallbacks,TFMMouseButtonCallbacks,TFMMouseDownCount,TFMMouseUpCount,TFMMouseMoveCount,TFMMouseDragCount,TFMMouseDispatchCount,TFMMouseCancelledCount,TFMMouseDroppedCount,TFMNativeHoverSamples;
static NSUInteger TFMMouseAttachedCount,TFMMousePressedButtons;
static BOOL TFMMouseHandlersRegistered,TFMMouseHasActualPoint,TFMMouseHovering;
static void TFMEnsureIndirectMouse(void);
static BOOL TFMIndirectMouseActive(void);
static void TFMIndirectMouseHover(CGPoint point,BOOL hovering);
static void TFMIndirectMouseViewWillDetach(UIView *view);
static void TFMTextInputViewWillDetach(UIView *view);
static BOOL TFMTextInputOverlayVisible(void);
static BOOL TFMHostAcceptsMouse(void);
static void TFMTextFocusBeforeUserTap(id target);
static void TFMTextFocusCancelPending(void);
static void TFMTextInputGestureRequested(void);
static void TFMTextFocusAfterUserTap(id target);
static NSMutableArray *TFMNativeInputTasks;
static void TFMQueueNativeInputTask(dispatch_block_t task) {
    if (!TFMNativeInputTasks) TFMNativeInputTasks=[NSMutableArray array];
    [TFMNativeInputTasks addObject:[task copy]];CFRunLoopWakeUp(CFRunLoopGetMain());
}
static void TFMDrainNativeInputTasks(void) {
    // Like queued NSEvents, text edits enter original winit outside UIKit's
    // control callbacks, avoiding a reentrant Rust application event callback.
    while (TFMNativeInputTasks.count) {
        dispatch_block_t task=TFMNativeInputTasks.firstObject;
        [TFMNativeInputTasks removeObjectAtIndex:0];task();
    }
}
static NSUInteger TFMDeliveredMouseButtons;
static void TFMRecordTouchInput(NSString *stage,NSUInteger type,NSInteger windowNumber) {
    uint64_t posted=TFMDirectTouchPostedWheelEvents()+TFMTouchDownCount+TFMTouchDragCount+TFMTouchUpCount+TFMMouseDownCount+TFMMouseUpCount+TFMMouseMoveCount+TFMMouseDragCount;
    if (posted<=16 || !(posted%120) || type==1 || type==2 || type==3 || type==4 || [stage hasPrefix:@"mouse-lifecycle"] || [stage hasPrefix:@"raw-touch"])
        TFMWriteDiagnostic(@"appkit-input.json",@{@"stage":stage,@"last_event_type":@(type),@"window_number":@(windowNumber),
            @"touch_down_posted":@(TFMTouchDownCount),@"touch_drag_posted":@(TFMTouchDragCount),@"touch_up_posted":@(TFMTouchUpCount),
            @"cancelled_streams":@(TFMTouchCancelCount),@"touch_events_dispatched":@(TFMTouchDispatchCount),@"multitouch_suppressed":@(TFMTouchSuppressedCount),
            @"raw_touch_began_entries":@(TFMRawTouchBeganEntries),@"raw_touch_missing_app_or_owner_window":@(TFMTouchMissingOwner),
            @"indirect_pointer_touches_ignored_for_active_mouse":@(TFMIndirectTouchesIgnored),
            @"mouse_connected_count":@(TFMMouseAttachedCount),@"mouse_handlers_registered":@(TFMMouseHandlersRegistered),
            @"mouse_movement_callbacks":@(TFMMouseMovementCallbacks),@"mouse_button_callbacks":@(TFMMouseButtonCallbacks),
            @"native_hover_samples":@(TFMNativeHoverSamples),@"mouse_has_actual_hover_coordinate":@(TFMMouseHasActualPoint),
            @"mouse_hover_inside_host":@(TFMMouseHovering),
            @"mouse_down_posted":@(TFMMouseDownCount),@"mouse_up_posted":@(TFMMouseUpCount),@"mouse_move_posted":@(TFMMouseMoveCount),
            @"mouse_drag_posted":@(TFMMouseDragCount),@"mouse_events_dispatched":@(TFMMouseDispatchCount),
            @"mouse_cancelled_button_streams":@(TFMMouseCancelledCount),@"mouse_callbacks_dropped":@(TFMMouseDroppedCount),
            @"mouse_posted_button_mask":@(TFMMousePressedButtons),@"application_active":@(UIApplication.sharedApplication.applicationState==UIApplicationStateActive),
            @"delivered_button_mask":@(TFMDeliveredMouseButtons),@"scope":@"actual UIKit touch/hover and GameController mouse callback counts; no menu/action success claim"});
    if (posted<=16 || !(posted%120))
        fprintf(stderr,"TFM_APPKIT_TOUCH stage=%s type=%lu posted=%llu dispatched=%llu cancelled=%llu\n",stage.UTF8String,(unsigned long)type,(unsigned long long)posted,(unsigned long long)TFMTouchDispatchCount,(unsigned long long)TFMTouchCancelCount);
}

static void TFMWriteDiagnostic(NSString *filename,NSDictionary *fields) {
    // Persist only bounded runtime metadata, never argv, paths, account state or
    // event contents. Atomic replacement leaves a complete prior record on error.
    @try {
        NSError *error=nil;
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        if (!documents || ![NSFileManager.defaultManager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr,"TFM_APPKIT_DIAGNOSTIC_WRITE_FAILED file=%s step=directory\n",filename.UTF8String);return;
        }
        NSMutableDictionary *record=[fields mutableCopy];
        record[@"pid"]=@(getpid());record[@"timestamp_unix"]=@(NSDate.date.timeIntervalSince1970);
        NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:&error];
        if (!data || ![data writeToURL:[documents URLByAppendingPathComponent:filename] options:NSDataWritingAtomic error:&error])
            fprintf(stderr,"TFM_APPKIT_DIAGNOSTIC_WRITE_FAILED file=%s step=json-write\n",filename.UTF8String);
    } @catch (NSException *exception) {
        // Diagnostics must not prevent a fail-fast exit or expose exception data.
        fprintf(stderr,"TFM_APPKIT_DIAGNOSTIC_WRITE_FAILED file=%s step=exception\n",filename.UTF8String);
    }
}

__attribute__((noreturn)) static void TFMUnsupported(id object, SEL selector) {
    const char *className=object?object_getClassName(object):"(nil)";
    const char *selectorName=selector?sel_getName(selector):"(null)";
    fprintf(stderr,"TFM_APPKIT_UNSUPPORTED class=%s selector=%s\n",
            className,selectorName);
    TFMWriteDiagnostic(@"appkit-failure.json",@{@"failure":@"unsupported-selector",
        @"class":@(className),@"selector":@(selectorName),
        @"class_method":@(object && class_isMetaClass(object_getClass(object))),
        @"main_thread":@(NSThread.isMainThread),@"exit_code":@78});
    fflush(stderr);_exit(78);
}
static void TFMRequireMainThread(const char *operation) {
    if (!NSThread.isMainThread) {
        NSString *location=@(operation),*className=@"TFMAppKit",*selectorName=location;
        // Clang's __func__ preserves Objective-C method spelling, e.g.
        // -[NSApplication run]. C API failures keep the C function name.
        NSRange open=[location rangeOfString:@"["],space=[location rangeOfString:@" "],close=[location rangeOfString:@"]" options:NSBackwardsSearch];
        if (open.location!=NSNotFound && space.location>open.location && space.location!=NSNotFound && close.location>space.location && close.location!=NSNotFound) {
            className=[location substringWithRange:NSMakeRange(open.location+1,space.location-open.location-1)];
            selectorName=[location substringWithRange:NSMakeRange(space.location+1,close.location-space.location-1)];
        }
        fprintf(stderr,"TFM_APPKIT_UNSUPPORTED main-thread-only operation=%s\n",operation);
        TFMWriteDiagnostic(@"appkit-failure.json",@{@"failure":@"main-thread-required",
            @"class":className,@"selector":selectorName,@"operation":location,
            @"main_thread":@NO,@"exit_code":@78});
        fflush(stderr);_exit(78);
    }
}
#define TFMMainThread() TFMRequireMainThread(__func__)
static void TFMCall(id object, SEL selector, id argument) {
    if (object && [object respondsToSelector:selector])
        ((void(*)(id,SEL,id))objc_msgSend)(object,selector,argument);
}
static NSNotification *TFMNotify(NSString *name,id object) {
    NSNotification *notification=[NSNotification notificationWithName:name object:object];
    [NSNotificationCenter.defaultCenter postNotification:notification];
    return notification;
}
@interface TFMAppKitObject : NSObject @end
@implementation TFMAppKitObject
- (void)doesNotRecognizeSelector:(SEL)selector { TFMUnsupported(self,selector); }
+ (void)doesNotRecognizeSelector:(SEL)selector { TFMUnsupported(self,selector); }
@end

@class NSView, NSWindow, NSApplication, NSCursor;
@interface NSAppearance : TFMAppKitObject
@property(nonatomic,copy) NSString *name;
+ (instancetype)currentAppearance;
+ (instancetype)appearanceNamed:(NSString *)name;
@end
@implementation NSAppearance
+ (instancetype)appearanceNamed:(NSString *)name {
    if (![name isEqual:NSAppearanceNameAqua] && ![name isEqual:TFMDarkAqua]) return nil;
    NSAppearance *appearance=[self new];appearance.name=name;return appearance;
}
+ (instancetype)currentAppearance {
    BOOL dark=TFMHostWindow.traitCollection.userInterfaceStyle==UIUserInterfaceStyleDark;
    return [self appearanceNamed:dark?TFMDarkAqua:NSAppearanceNameAqua];
}
- (NSString *)bestMatchFromAppearancesWithNames:(NSArray *)names {
    if ([names containsObject:self.name]) return self.name;
    for (NSString *name in names)
        if ([name isEqual:NSAppearanceNameAqua] || [name isEqual:TFMDarkAqua]) return name;
    return nil;
}
@end

@interface NSScreen : TFMAppKitObject
@property(nonatomic,strong) UIScreen *nativeScreen;
+ (instancetype)mainScreen;
+ (NSArray *)screens;
- (CGRect)frame;
- (CGFloat)backingScaleFactor;
@end
@implementation NSScreen
+ (instancetype)mainScreen {
    TFMMainThread();if (!TFMHostWindow) return nil;
    static NSScreen *screen;static dispatch_once_t once;
    dispatch_once(&once,^{screen=[self new];});
    screen.nativeScreen=TFMHostWindow.windowScene.screen ?: TFMHostWindow.screen;
    return screen;
}
+ (NSArray *)screens { NSScreen *screen=[self mainScreen];return screen?@[screen]:@[]; }
+ (BOOL)screensHaveSeparateSpaces { return NO; }
- (CGRect)frame { return self.nativeScreen.bounds; }
- (CGRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return self.nativeScreen.scale; }
- (NSInteger)maximumFramesPerSecond { return self.nativeScreen.maximumFramesPerSecond; }
- (NSDictionary *)deviceDescription { return @{@"NSScreenNumber":@1}; }
- (NSString *)localizedName { return @"UIKit host screen"; }
@end

@interface NSEvent : TFMAppKitObject
@property(nonatomic) NSUInteger type,modifierFlags;
@property(nonatomic) CGPoint locationInWindow;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic) NSInteger windowNumber,buttonNumber,clickCount,eventNumber,data1,data2;
@property(nonatomic) int16_t subtype;
@property(nonatomic) CGFloat deltaX,deltaY,scrollingDeltaX,scrollingDeltaY;
@property(nonatomic) unsigned short keyCode;
@property(nonatomic) BOOL isARepeat;
@property(nonatomic) BOOL tfmNativeTouch,tfmNativeMouse,tfmCancelled,hasPreciseScrollingDeltas,isDirectionInvertedFromDevice;
@property(nonatomic) NSUInteger phase,momentumPhase;
@property(nonatomic) float pressure;
@property(nonatomic,copy) NSString *characters,*charactersIgnoringModifiers;
// Queued mouse events retain their actual window/target through a balanced up,
// even if UIKit detaches that view before the application drains its queue.
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSView *tfmInputTarget;
@property(nonatomic,strong) id context;
@end
static NSEvent *TFMCurrentEvent;
@implementation NSEvent
+ (instancetype)otherEventWithType:(NSUInteger)type location:(CGPoint)point modifierFlags:(NSUInteger)flags timestamp:(NSTimeInterval)time windowNumber:(NSInteger)number context:(id)context subtype:(int16_t)subtype data1:(NSInteger)data1 data2:(NSInteger)data2 {
    if (type<13 || type>16) TFMUnsupported(self,_cmd);
    NSEvent *event=[self new];event.type=type;event.locationInWindow=point;
    event.modifierFlags=flags;event.timestamp=time;event.windowNumber=number;
    event.context=context;event.subtype=subtype;event.data1=data1;event.data2=data2;return event;
}
+ (NSUInteger)modifierFlags { return TFMCurrentEvent.modifierFlags; }
+ (NSUInteger)pressedMouseButtons { return TFMDeliveredMouseButtons; }
+ (CGPoint)mouseLocation {
    if (!TFMCurrentEvent) TFMUnsupported(self,_cmd);
    return TFMCurrentEvent.locationInWindow;
}
+ (NSTimeInterval)doubleClickInterval { return 0.3; } // Explicit app-local policy.
@end

@interface NSApplication : TFMAppKitObject
@property(nonatomic,weak) id delegate;
@property(nonatomic,strong) id mainMenu,servicesMenu;
@property(nonatomic,strong) NSMutableArray<NSEvent *> *tfmEvents;
@property(nonatomic) BOOL tfmLaunched,tfmRunning;
@property(nonatomic) NSInteger tfmActivationPolicy;
@property(nonatomic) NSUInteger presentationOptions;
+ (instancetype)sharedApplication;
- (void)finishLaunching;
- (void)sendEvent:(NSEvent *)event;
- (NSArray *)windows;
@end
NSApplication *NSApp;
@implementation NSApplication
+ (instancetype)sharedApplication {
    TFMMainThread();
    if (!NSApp) { NSApp=[[self alloc] init];fprintf(stderr,"TFM_APPKIT_APPLICATION class=%s\n",object_getClassName(NSApp));TFMRecordProgress(@"application-created"); }
    return NSApp;
}
- (instancetype)init {
    if ((self=[super init])) _tfmEvents=[NSMutableArray array];return self;
}
- (void)setDelegate:(id)delegate { TFMMainThread();_delegate=delegate;TFMRecordProgress(@"delegate-assigned"); }
- (BOOL)setActivationPolicy:(NSInteger)policy {
    TFMMainThread();if (policy<0 || policy>2) return NO;
    self.tfmActivationPolicy=policy;return YES;
}
- (NSInteger)activationPolicy { return self.tfmActivationPolicy; }
- (BOOL)isActive { return TFMHostWindow && UIApplication.sharedApplication.applicationState==UIApplicationStateActive; }
- (BOOL)isHidden { return !TFMHostWindow || TFMHostWindow.hidden; }
- (BOOL)isRunning { return self.tfmRunning; }
- (id)keyWindow { return TFMKeyWindow; }
- (id)mainWindow { return TFMMainWindow; }
- (NSArray *)windows { return TFMWindows.allObjects ?: @[]; }
- (NSEvent *)currentEvent { return TFMCurrentEvent; }
- (NSAppearance *)effectiveAppearance { return NSAppearance.currentAppearance; }
- (void)activateIgnoringOtherApps:(BOOL)ignore {
    TFMMainThread();if (!TFMHostWindow || UIApplication.sharedApplication.applicationState==UIApplicationStateBackground) TFMUnsupported(self,_cmd);
    [TFMHostWindow makeKeyAndVisible];
}
- (void)finishLaunching {
    TFMMainThread();if (self.tfmLaunched) return;
    if (!TFMHostWindow.windowScene || !TFMHostWindow.rootViewController) TFMUnsupported(self,_cmd);
    self.tfmLaunched=YES;
    TFMRecordProgress(@"finish-launching-begin");
    fprintf(stderr,"TFM_APPKIT_FINISH_LAUNCH delegate=%s\n",object_getClassName(self.delegate));fflush(stderr);
    NSNotification *will=TFMNotify(@"NSApplicationWillFinishLaunchingNotification",self);
    TFMCall(self.delegate,@selector(applicationWillFinishLaunching:),will);
    NSNotification *did=TFMNotify(@"NSApplicationDidFinishLaunchingNotification",self);
    TFMCall(self.delegate,@selector(applicationDidFinishLaunching:),did);
    TFMRecordProgress(@"finish-launching-returned");
}
- (void)run {
    TFMMainThread();if (self.tfmRunning || !TFMHostWindow) TFMUnsupported(self,_cmd);
    TFMRunInvocationCount++;TFMRecordProgress(@"run-invoked");
    self.tfmRunning=YES;
    [self finishLaunching];
    fprintf(stderr,"TFM_APPKIT_RUN_BEGIN nested-uikit-runloop=1\n");fflush(stderr);
    while (self.tfmRunning) {
        @autoreleasepool {
            while (self.tfmEvents.count && self.tfmRunning) {
                NSEvent *event=self.tfmEvents.firstObject;[self.tfmEvents removeObjectAtIndex:0];[self sendEvent:event];
            }
            if (self.tfmRunning) TFMDrainNativeInputTasks();
            if (self.tfmRunning) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,true);
        }
    }
    fprintf(stderr,"TFM_APPKIT_RUN_END\n");fflush(stderr);
    TFMRecordProgress(@"run-returned");
}
- (void)stop:(id)sender { TFMMainThread();self.tfmRunning=NO;TFMRecordProgress(@"stop-requested");CFRunLoopWakeUp(CFRunLoopGetMain()); }
- (void)terminate:(id)sender { TFMCall(self.delegate,@selector(applicationWillTerminate:),TFMNotify(@"NSApplicationWillTerminateNotification",self));exit(0); }
- (void)postEvent:(NSEvent *)event atStart:(BOOL)start {
    TFMMainThread();if (!event) TFMUnsupported(self,_cmd);
    if (start) [self.tfmEvents insertObject:event atIndex:0];else [self.tfmEvents addObject:event];
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask untilDate:(NSDate *)date inMode:(NSString *)mode dequeue:(BOOL)dequeue {
    TFMMainThread();if (!date || ![mode isEqual:NSDefaultRunLoopMode]) TFMUnsupported(self,_cmd);
    for (;;) {
        TFMDrainNativeInputTasks();
        for (NSUInteger i=0;i<self.tfmEvents.count;i++) {
            NSEvent *event=self.tfmEvents[i];
            if (event.type<64 && (mask & (1ULL<<event.type))) {
                if (dequeue) [self.tfmEvents removeObjectAtIndex:i];return event;
            }
        }
        NSTimeInterval remaining=date.timeIntervalSinceNow;if (remaining<=0) return nil;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,MIN(remaining,0.01),true);
    }
}
- (void)sendEvent:(NSEvent *)event {
    TFMMainThread();NSEvent *previous=TFMCurrentEvent;TFMCurrentEvent=event;
    if (event.type==1) TFMDeliveredMouseButtons|=1UL;
    else if (event.type==2) TFMDeliveredMouseButtons&=~1UL;
    else if (event.type==3) TFMDeliveredMouseButtons|=2UL;
    else if (event.type==4) TFMDeliveredMouseButtons&=~2UL;
    if (event.window) TFMCall(event.window,@selector(sendEvent:),event);
    else if (event.type<13 || event.type>16) TFMUnsupported(self,_cmd);
    if (event.tfmNativeTouch) { TFMTouchDispatchCount++;TFMRecordTouchInput(@"dispatched-to-window",event.type,event.windowNumber); }
    if (event.tfmNativeMouse) { TFMMouseDispatchCount++;TFMRecordTouchInput(@"mouse-dispatched-to-window",event.type,event.windowNumber); }
    TFMCurrentEvent=previous;
}
- (void)updateWindows { for (id window in self.windows) TFMCall(window,@selector(update),nil); }
@end

@interface NSTextInputContext : TFMAppKitObject
@property(nonatomic,weak) NSView *client;
@end
@interface TFMNativeView : UIView
@property(nonatomic,weak) NSView *owner;
@property(nonatomic,strong) UITouch *tfmPrimaryTouch;
@property(nonatomic,strong) NSWindow *tfmTouchWindow;
@property(nonatomic,strong) NSView *tfmTouchTarget;
@property(nonatomic) CGPoint tfmLastTouchPoint;
@property(nonatomic) NSUInteger tfmLastTouchModifiers;
@property(nonatomic) BOOL tfmSuppressTouches;
- (void)tfmCancelTouchAtTimestamp:(NSTimeInterval)timestamp;
@end
@interface NSView : TFMAppKitObject
@property(nonatomic,strong) TFMNativeView *tfmNative;
@property(nonatomic,weak) NSView *superview;
@property(nonatomic,weak) NSWindow *tfmWindow;
@property(nonatomic,strong) NSMutableArray<NSView *> *tfmSubviews;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,id> *tfmTracking;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *tfmCursorRects;
@property(nonatomic,strong) NSTextInputContext *tfmInput;
@property(nonatomic) CGRect tfmFrame;
@property(nonatomic) BOOL postsFrameChangedNotifications,wantsBestResolutionOpenGLSurface;
@property(nonatomic) BOOL tfmNeedsDisplay;
@property(nonatomic,weak) id nextResponder;
- (instancetype)initWithFrame:(CGRect)frame;
- (CGRect)frame;
- (void)setFrame:(CGRect)frame;
- (CGRect)bounds;
- (NSWindow *)window;
- (BOOL)isFlipped;
- (void)drawRect:(CGRect)rect;
- (void)discardCursorRects;
- (void)resetCursorRects;
@end
@interface NSWindow : TFMAppKitObject
@property(nonatomic,weak) id delegate;
@property(nonatomic,strong) NSView *contentView;
@property(nonatomic,strong) id firstResponder,initialFirstResponder;
@property(nonatomic,strong) NSView *tfmMouseCaptureView;
@property(nonatomic,copy) NSString *title;
@property(nonatomic) BOOL releasedWhenClosed,acceptsMouseMovedEvents,opaque,hasShadow;
@property(nonatomic) NSUInteger styleMask,collectionBehavior;
@property(nonatomic) NSInteger level,windowNumber;
@property(nonatomic) CGRect tfmFrame;
@property(nonatomic) CGSize contentMinSize,contentMaxSize,resizeIncrements;
@property(nonatomic) BOOL tfmVisible,tfmZoomed;
@property(nonatomic) BOOL tfmCanvasFullscreen,tfmFullscreenTransition,tfmPendingFullscreenToggle;
@property(nonatomic) CGRect tfmSavedWindowedFrame;
@property(nonatomic,strong) NSAppearance *appearance;
@property(nonatomic,copy) NSArray *tfmDraggedTypes;
- (CGRect)frame;
- (NSAppearance *)effectiveAppearance;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)toggleFullScreen:(id)sender;
@end

#include "TFMDirectTouch.inc"
@implementation NSTextInputContext
- (NSString *)selectedKeyboardInputSource {
    // A labeled UIKit locale hint; not a macOS TIS layout ID or IME emulation.
    return [@"TFMUIKitLocale:" stringByAppendingString:NSLocale.currentLocale.localeIdentifier];
}
- (BOOL)activate { return [self.client.tfmNative becomeFirstResponder]; }
- (void)deactivate { [self.client.tfmNative resignFirstResponder]; }
- (BOOL)handleEvent:(id)event { return NO; } // No text event was consumed.
- (void)invalidateCharacterCoordinates { /* No marked text/IME candidate UI is installed. */ }
- (void)discardMarkedText { /* This context owns no marked text. */ }
@end

static void TFMApplyNativeFrame(NSView *view) {
    CGRect frame=view.tfmFrame;
    if (view.superview && !view.superview.isFlipped) frame.origin.y=view.superview.bounds.size.height-CGRectGetMaxY(frame);
    view.tfmNative.frame=frame;
}
@implementation NSView
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (instancetype)initWithFrame:(CGRect)frame {
    TFMMainThread();if ((self=[super init])) {
        _tfmFrame=frame;_tfmNative=[[TFMNativeView alloc] initWithFrame:frame];_tfmNative.owner=self;
        _tfmNative.multipleTouchEnabled=YES;
        _tfmNative.opaque=NO;_tfmNative.backgroundColor=UIColor.clearColor;
        _tfmSubviews=[NSMutableArray array];_tfmTracking=[NSMutableDictionary dictionary];
        _tfmCursorRects=[NSMutableArray array];
    }return self;
}
- (CGRect)frame { return self.tfmFrame; }
- (void)setFrame:(CGRect)frame {
    TFMMainThread();BOOL changed=!CGRectEqualToRect(frame,self.tfmFrame);self.tfmFrame=frame;TFMApplyNativeFrame(self);
    if (changed && self.postsFrameChangedNotifications) TFMNotify(NSViewFrameDidChangeNotification,self);
}
- (void)setFrameSize:(CGSize)size { CGRect frame=self.frame;frame.size=size;self.frame=frame; }
- (void)setFrameOrigin:(CGPoint)origin { CGRect frame=self.frame;frame.origin=origin;self.frame=frame; }
- (CGRect)bounds { return self.tfmNative.bounds; }
- (void)setBounds:(CGRect)bounds { self.tfmNative.bounds=bounds; }
- (BOOL)isFlipped { return NO; }
- (NSArray *)subviews { return self.tfmSubviews.copy; }
- (NSWindow *)window { return self.tfmWindow ?: self.superview.window; }
- (CALayer *)layer { return self.tfmNative.layer; }
- (BOOL)wantsLayer { return YES; }
- (void)setWantsLayer:(BOOL)wanted { if (!wanted) TFMUnsupported(self,_cmd); }
- (void)addSubview:(NSView *)view {
    TFMMainThread();if (!view || view==self) TFMUnsupported(self,_cmd);
    [view removeFromSuperview];view.superview=self;[self.tfmSubviews addObject:view];
    TFMApplyNativeFrame(view);[self.tfmNative addSubview:view.tfmNative];
    TFMCall(view,@selector(viewDidMoveToWindow),nil);
}
- (void)removeFromSuperview {
    TFMMainThread();[self.superview.tfmSubviews removeObjectIdenticalTo:self];self.superview=nil;
    self.tfmWindow=nil;[self.tfmNative removeFromSuperview];TFMCall(self,@selector(viewDidMoveToWindow),nil);
}
- (BOOL)isHidden { return self.tfmNative.hidden; }
- (void)setHidden:(BOOL)hidden { self.tfmNative.hidden=hidden; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return [self.tfmNative becomeFirstResponder]; }
- (BOOL)resignFirstResponder { return [self.tfmNative resignFirstResponder]; }
- (BOOL)isFirstResponder { return self.tfmNative.isFirstResponder; }
- (NSTextInputContext *)inputContext {
    if (!self.tfmInput) { self.tfmInput=[NSTextInputContext new];self.tfmInput.client=self; }
    return self.tfmInput;
}
- (NSAppearance *)effectiveAppearance { return self.window.effectiveAppearance ?: NSAppearance.currentAppearance; }
- (void)setAutoresizingMask:(NSUInteger)mask {
    if (mask & ~63UL) TFMUnsupported(self,_cmd);
    self.tfmNative.autoresizingMask=(UIViewAutoresizing)mask;
}
- (void)setNeedsDisplay:(BOOL)needed { self.tfmNeedsDisplay=needed;if (needed) [self.tfmNative setNeedsDisplay]; }
- (BOOL)needsDisplay { return self.tfmNeedsDisplay; }
- (void)displayIfNeeded { [self.tfmNative.layer displayIfNeeded]; }
- (void)display { [self setNeedsDisplay:YES];[self.tfmNative.layer displayIfNeeded]; }
- (void)drawRect:(CGRect)rect { /* Base view paints no game content. Subclasses handle redraw. */ }
- (void)viewDidMoveToWindow { }
- (void)resetCursorRects { }
- (void)addCursorRect:(CGRect)rect cursor:(NSCursor *)cursor {
    TFMMainThread();
    if (!cursor || !isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(rect.size.width) || !isfinite(rect.size.height) || rect.size.width<0 || rect.size.height<0) TFMUnsupported(self,_cmd);
    [self.tfmCursorRects addObject:@{@"rect":[NSValue valueWithCGRect:rect],@"cursor":cursor}];
    TFMRefreshCursorRegions();
}
- (void)removeCursorRect:(CGRect)rect cursor:(NSCursor *)cursor {
    TFMMainThread();NSIndexSet *matches=[self.tfmCursorRects indexesOfObjectsPassingTest:^BOOL(NSDictionary *record,NSUInteger index,BOOL *stop) {
        (void)index;(void)stop;
        return record[@"cursor"]==cursor && CGRectEqualToRect([record[@"rect"] CGRectValue],rect);
    }];
    [self.tfmCursorRects removeObjectsAtIndexes:matches];TFMRefreshCursorRegions();
}
- (void)discardCursorRects { TFMMainThread();[self.tfmCursorRects removeAllObjects];TFMRefreshCursorRegions(); }
- (NSInteger)addTrackingRect:(CGRect)rect owner:(id)owner userData:(void *)data assumeInside:(BOOL)inside {
    if (data || inside) TFMUnsupported(self,_cmd);
    NSInteger token=TFMTrackingSequence++;self.tfmTracking[@(token)]=@{@"rect":[NSValue valueWithCGRect:rect],@"owner":[NSValue valueWithNonretainedObject:owner]};
    return token; // Registration only; hover delivery remains unimplemented.
}
- (void)removeTrackingRect:(NSInteger)token { [self.tfmTracking removeObjectForKey:@(token)]; }
- (CGPoint)convertPoint:(CGPoint)point toView:(NSView *)view {
    if (!self.isFlipped) point.y=self.bounds.size.height-point.y;
    UIView *windowContent=self.window.contentView.tfmNative ?: TFMHostWindow;
    CGPoint result=[self.tfmNative convertPoint:point toView:view?view.tfmNative:windowContent];
    BOOL targetFlipped=view?view.isFlipped:NO;CGFloat height=view?view.bounds.size.height:windowContent.bounds.size.height;
    if (!targetFlipped) result.y=height-result.y;return result;
}
- (CGPoint)convertPoint:(CGPoint)point fromView:(NSView *)view {
    UIView *windowContent=self.window.contentView.tfmNative ?: TFMHostWindow;
    BOOL sourceFlipped=view?view.isFlipped:NO;CGFloat height=view?view.bounds.size.height:windowContent.bounds.size.height;
    if (!sourceFlipped) point.y=height-point.y;
    CGPoint result=[self.tfmNative convertPoint:point fromView:view?view.tfmNative:windowContent];
    if (!self.isFlipped) result.y=self.bounds.size.height-result.y;return result;
}
- (CGRect)convertRectToBacking:(CGRect)rect { CGFloat s=self.window?TFMHostWindow.screen.scale:UIScreen.mainScreen.scale;return CGRectMake(rect.origin.x*s,rect.origin.y*s,rect.size.width*s,rect.size.height*s); }
- (CGRect)convertRectFromBacking:(CGRect)rect { CGFloat s=TFMHostWindow.screen.scale ?: UIScreen.mainScreen.scale;return CGRectMake(rect.origin.x/s,rect.origin.y/s,rect.size.width/s,rect.size.height/s); }
@end

static void TFMWindowNotify(NSWindow *window,NSString *name,SEL action) { TFMCall(window.delegate,action,TFMNotify(name,window)); }
static void TFMLayoutContent(NSWindow *window) {
    UIView *root=TFMHostWindow.rootViewController.view;CGRect frame=window.tfmFrame;
    frame.origin.y=root.bounds.size.height-CGRectGetMaxY(frame);
    window.contentView.tfmNative.frame=frame;
    window.contentView.tfmFrame=(CGRect){CGPointZero,frame.size};
}
@implementation NSWindow
@synthesize styleMask=_styleMask;
- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer {
    TFMMainThread();if (!TFMHostWindow.windowScene || backing!=2) TFMUnsupported(self,_cmd);
    if ((self=[super init])) {
        _tfmFrame=rect;_styleMask=style & ~TFMFullScreenStyleMask;_title=@"";_opaque=YES;_hasShadow=NO;
        _windowNumber=TFMWindowSequence++;_contentMaxSize=CGSizeMake(CGFLOAT_MAX,CGFLOAT_MAX);_resizeIncrements=CGSizeMake(1,1);
        if (!TFMWindows) TFMWindows=[NSHashTable weakObjectsHashTable];[TFMWindows addObject:self];
        self.contentView=[[NSView alloc] initWithFrame:(CGRect){CGPointZero,rect.size}];
        TFMRecordProgress(@"window-created");
        fprintf(stderr,"TFM_APPKIT_WINDOW_CREATE number=%ld size=%gx%g\n",(long)_windowNumber,rect.size.width,rect.size.height);fflush(stderr);
    }return self;
}
+ (BOOL)allowsAutomaticWindowTabbing { return NO; }
+ (void)setAllowsAutomaticWindowTabbing:(BOOL)enabled { if (enabled) TFMUnsupported(self,_cmd); }
- (void)setContentView:(NSView *)view {
    TFMMainThread();if (_contentView==view) return;
    [_contentView.tfmNative removeFromSuperview];_contentView.tfmWindow=nil;_contentView=view;view.tfmWindow=self;
    TFMLayoutContent(self);if (self.tfmVisible) [TFMHostWindow.rootViewController.view addSubview:view.tfmNative];
    TFMCall(view,@selector(viewDidMoveToWindow),nil);
}
- (CGRect)frame { return self.tfmFrame; }
- (NSUInteger)styleMask { return (_styleMask & ~TFMFullScreenStyleMask) | (self.tfmCanvasFullscreen?TFMFullScreenStyleMask:0); }
- (void)setStyleMask:(NSUInteger)style { _styleMask=style & ~TFMFullScreenStyleMask; }
- (void)setFrame:(CGRect)frame display:(BOOL)display {
    TFMMainThread();
    // Fullscreen describes this game's current UIKit canvas, never a hardware
    // display mode. Keep it filling the actual content area after size requests.
    if (self.tfmCanvasFullscreen) frame=(CGRect){CGPointZero,TFMHostWindow.rootViewController.view.bounds.size};
    CGSize old=self.tfmFrame.size;self.tfmFrame=frame;TFMLayoutContent(self);
    if (!CGSizeEqualToSize(old,frame.size)) {
        if (self.contentView.postsFrameChangedNotifications) TFMNotify(NSViewFrameDidChangeNotification,self.contentView);
        TFMWindowNotify(self,@"NSWindowDidResizeNotification",@selector(windowDidResize:));
    }
    if (display) [self.contentView setNeedsDisplay:YES];
}
- (void)setFrame:(CGRect)frame display:(BOOL)display animate:(BOOL)animate { [self setFrame:frame display:display]; }
- (void)setContentSize:(CGSize)size { CGRect frame=self.tfmFrame;frame.size=size;[self setFrame:frame display:YES]; }
- (void)toggleFullScreen:(id)sender {
    TFMMainThread();
    if (!TFMHostWindow.windowScene || !TFMHostWindow.rootViewController) TFMUnsupported(self,_cmd);
    if (self.tfmFullscreenTransition) {
        // Preserve the net meaning of repeated toggle requests during a pending
        // transition rather than recursively calling the original Rust delegate.
        self.tfmPendingFullscreenToggle=!self.tfmPendingFullscreenToggle;return;
    }
    self.tfmFullscreenTransition=YES;
    BOOL entering=!self.tfmCanvasFullscreen;
    if (entering) self.tfmSavedWindowedFrame=self.tfmFrame;
    TFMRecordProgress(entering?@"fullscreen-enter-requested":@"fullscreen-exit-requested");
    // winit calls this from WindowDelegate::new, before its caller finishes
    // initializing the window. Native AppKit transitions are asynchronous too;
    // deliver the whole will/resize/did sequence only after that stack unwinds.
    dispatch_async(dispatch_get_main_queue(),^{
        TFMWindowNotify(self,entering?@"NSWindowWillEnterFullScreenNotification":@"NSWindowWillExitFullScreenNotification",
                        entering?@selector(windowWillEnterFullScreen:):@selector(windowWillExitFullScreen:));
        self.tfmCanvasFullscreen=entering;
        CGRect destination=entering?(CGRect){CGPointZero,TFMHostWindow.rootViewController.view.bounds.size}:self.tfmSavedWindowedFrame;
        [self setFrame:destination display:YES];
        [self.contentView.tfmNative layoutIfNeeded];
        fprintf(stderr,"TFM_APPKIT_FULLSCREEN entering=%d scope=uikit-game-canvas frame=%g,%g,%g,%g desktop_spaces_changed=0 display_mode_changed=0\n",
                entering,self.tfmFrame.origin.x,self.tfmFrame.origin.y,self.tfmFrame.size.width,self.tfmFrame.size.height);
        // UIKit geometry and the fullscreen style bit are already updated when
        // winit handles DidEnter/DidExit and restores any saved ordinary style.
        TFMWindowNotify(self,entering?@"NSWindowDidEnterFullScreenNotification":@"NSWindowDidExitFullScreenNotification",
                        entering?@selector(windowDidEnterFullScreen:):@selector(windowDidExitFullScreen:));
        self.tfmFullscreenTransition=NO;
        TFMRecordProgress(entering?@"fullscreen-entered":@"fullscreen-exited");
        if (self.tfmPendingFullscreenToggle) {
            self.tfmPendingFullscreenToggle=NO;[self toggleFullScreen:nil];
        }
    });
}
- (CGRect)contentLayoutRect { return (CGRect){CGPointZero,self.tfmFrame.size}; }
- (CGRect)contentRectForFrameRect:(CGRect)rect { return rect; }
- (CGRect)frameRectForContentRect:(CGRect)rect { return rect; }
+ (CGRect)contentRectForFrameRect:(CGRect)rect styleMask:(NSUInteger)style { return rect; }
+ (CGRect)frameRectForContentRect:(CGRect)rect styleMask:(NSUInteger)style { return rect; }
- (NSScreen *)screen { return NSScreen.mainScreen; }
- (CGFloat)backingScaleFactor { return TFMHostWindow.screen.scale; }
- (NSAppearance *)effectiveAppearance { return self.appearance ?: NSAppearance.currentAppearance; }
+ (NSSet *)keyPathsForValuesAffectingEffectiveAppearance { return [NSSet setWithObject:@"appearance"]; }
- (void)setAppearance:(NSAppearance *)appearance {
    _appearance=appearance;
    self.contentView.tfmNative.overrideUserInterfaceStyle=appearance?[appearance.name isEqual:TFMDarkAqua]?UIUserInterfaceStyleDark:UIUserInterfaceStyleLight:UIUserInterfaceStyleUnspecified;
}
- (void)setOpaque:(BOOL)opaque { _opaque=opaque;self.contentView.tfmNative.opaque=opaque; }
- (void)setHasShadow:(BOOL)shadow { if (shadow) TFMUnsupported(self,_cmd);_hasShadow=NO; }
- (void)center { CGRect rect=self.tfmFrame,bounds=TFMHostWindow.rootViewController.view.bounds;rect.origin=CGPointMake((bounds.size.width-rect.size.width)/2,(bounds.size.height-rect.size.height)/2);[self setFrame:rect display:NO]; }
- (void)orderFront:(id)sender {
    TFMMainThread();TFMLayoutContent(self);[TFMHostWindow.rootViewController.view addSubview:self.contentView.tfmNative];
    self.contentView.tfmNative.hidden=NO;self.tfmVisible=YES;[TFMHostWindow makeKeyAndVisible];
    [self.contentView setNeedsDisplay:YES];
    TFMRecordProgress(@"window-visible");
    TFMRefreshCursorRegions();
}
- (void)invalidateCursorRectsForView:(NSView *)view {
    TFMMainThread();if (!view || view.window!=self) TFMUnsupported(self,_cmd);
    [view discardCursorRects];
    // Dispatch the actual subclass override: WinitView registers its current
    // visible/custom/invisible cursor from inside resetCursorRects.
    [view resetCursorRects];TFMRefreshCursorRegions();
    fprintf(stderr,"TFM_APPKIT_CURSOR_RECTS_INVALIDATED view=%s registered=%lu native_pointer_invalidated=1\n",object_getClassName(view),(unsigned long)view.tfmCursorRects.count);
}
- (void)discardCursorRects {
    TFMMainThread();NSMutableArray<NSView *> *pending=[NSMutableArray array];
    if (self.contentView) [pending addObject:self.contentView];
    while (pending.count) {
        NSView *view=pending.lastObject;[pending removeLastObject];
        [view.tfmCursorRects removeAllObjects];[pending addObjectsFromArray:view.tfmSubviews];
    }
    TFMRefreshCursorRegions();
}
- (void)makeKeyAndOrderFront:(id)sender { [self orderFront:sender];[self makeKeyWindow];[self makeMainWindow]; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)makeKeyWindow {
    if (!self.tfmVisible || TFMKeyWindow==self) return;
    TFMCall(TFMKeyWindow,@selector(resignKeyWindow),nil);TFMKeyWindow=self;
    [self makeFirstResponder:self.initialFirstResponder ?: self.contentView];
    TFMWindowNotify(self,@"NSWindowDidBecomeKeyNotification",@selector(windowDidBecomeKey:));
}
- (void)makeMainWindow { if (self.tfmVisible && TFMMainWindow!=self) { TFMCall(TFMMainWindow,@selector(resignMainWindow),nil);TFMMainWindow=self;TFMWindowNotify(self,@"NSWindowDidBecomeMainNotification",@selector(windowDidBecomeMain:)); } }
- (void)resignKeyWindow { if (TFMKeyWindow==self) { TFMKeyWindow=nil;TFMWindowNotify(self,@"NSWindowDidResignKeyNotification",@selector(windowDidResignKey:)); } }
- (void)resignMainWindow { if (TFMMainWindow==self) { TFMMainWindow=nil;TFMWindowNotify(self,@"NSWindowDidResignMainNotification",@selector(windowDidResignMain:)); } }
- (BOOL)isKeyWindow { return TFMKeyWindow==self && TFMHostWindow.isKeyWindow; }
- (BOOL)isMainWindow { return TFMMainWindow==self; }
- (BOOL)isVisible { return self.tfmVisible && !TFMHostWindow.hidden; }
- (BOOL)isMiniaturized { return NO; }
- (BOOL)isOnActiveSpace { return UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground; }
- (BOOL)inLiveResize { return NO; }
- (BOOL)isZoomed { return self.tfmZoomed; }
- (BOOL)makeFirstResponder:(id)responder {
    if (!responder) { [self.firstResponder resignFirstResponder];self.firstResponder=nil;return YES; }
    if (![responder becomeFirstResponder]) return NO;self.firstResponder=responder;return YES;
}
- (void)orderOut:(id)sender { self.tfmVisible=NO;[self.contentView.tfmNative removeFromSuperview];[self resignKeyWindow];[self resignMainWindow]; }
- (void)close { TFMWindowNotify(self,@"NSWindowWillCloseNotification",@selector(windowWillClose:));[self orderOut:nil]; }
- (void)update { [self.contentView displayIfNeeded]; }
- (void)sendEvent:(NSEvent *)event {
    NSArray *actions=@[@"",@"mouseDown:",@"mouseUp:",@"rightMouseDown:",@"rightMouseUp:",@"mouseMoved:",@"mouseDragged:",@"rightMouseDragged:",@"mouseEntered:",@"mouseExited:",@"keyDown:",@"keyUp:",@"flagsChanged:"];
    if (event.type==1 || event.type==3) self.tfmMouseCaptureView=self.tfmMouseCaptureView ?: event.tfmInputTarget ?: self.contentView;
    id target=(event.type>=10 && event.type<=12)?(self.firstResponder ?: self.contentView):(self.tfmMouseCaptureView ?: event.tfmInputTarget ?: self.contentView);
    if (event.type>0 && event.type<actions.count) TFMCall(target,NSSelectorFromString(actions[event.type]),event);
    else if (event.type==22) TFMCall(self.contentView,@selector(scrollWheel:),event);
    else if (event.type<13 || event.type>16) TFMUnsupported(self,_cmd);
    if ((event.type==2 || event.type==4) && !(TFMDeliveredMouseButtons&3UL)) self.tfmMouseCaptureView=nil;
}
- (void)registerForDraggedTypes:(NSArray *)types { self.tfmDraggedTypes=types; } // Registration only; no drag operation is reported.
- (void)unregisterDraggedTypes { self.tfmDraggedTypes=nil; }
- (id)standardWindowButton:(NSUInteger)button { return nil; } // No AppKit titlebar buttons in this UIKit content window.
- (CGPoint)convertPointToScreen:(CGPoint)point { return CGPointMake(self.frame.origin.x+point.x,self.frame.origin.y+point.y); }
- (CGPoint)convertPointFromScreen:(CGPoint)point { return CGPointMake(point.x-self.frame.origin.x,point.y-self.frame.origin.y); }
- (CGRect)convertRectToScreen:(CGRect)rect { rect.origin=[self convertPointToScreen:rect.origin];return rect; }
- (CGRect)convertRectFromScreen:(CGRect)rect { rect.origin=[self convertPointFromScreen:rect.origin];return rect; }
- (void)setTitlebarAppearsTransparent:(BOOL)value { fprintf(stderr,"TFM_APPKIT_CHROME no-desktop-titlebar transparent=%d\n",value); }
- (void)setTitleVisibility:(NSInteger)value { if (value!=0 && value!=1) TFMUnsupported(self,_cmd); }
@end

@interface NSMenu : TFMAppKitObject
@property(nonatomic,copy) NSString *title;
@property(nonatomic) BOOL autoenablesItems;
@property(nonatomic,strong) NSMutableArray *tfmItems;
@end
@interface NSMenuItem : TFMAppKitObject
@property(nonatomic,copy) NSString *title,*keyEquivalent;
@property(nonatomic) NSUInteger keyEquivalentModifierMask;
@property(nonatomic) SEL action;
@property(nonatomic,weak) id target;
@property(nonatomic,strong) NSMenu *submenu;
@property(nonatomic,weak) NSMenu *menu;
@property(nonatomic) NSInteger tag,state;
@property(nonatomic,getter=isEnabled) BOOL enabled;
@property(nonatomic,getter=isHidden) BOOL hidden;
@property(nonatomic,getter=isSeparatorItem) BOOL separatorItem;
@end
@implementation NSMenuItem
- (instancetype)init { return [self initWithTitle:@"" action:NULL keyEquivalent:@""]; }
- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key {
    if ((self=[super init])) { _title=[title copy];_action=action;_keyEquivalent=[key copy];_enabled=YES;_keyEquivalentModifierMask=1UL<<20; }return self;
}
+ (instancetype)separatorItem { NSMenuItem *item=[self new];item.separatorItem=YES;return item; }
@end
@implementation NSMenu
- (instancetype)init { return [self initWithTitle:@""]; }
- (instancetype)initWithTitle:(NSString *)title { if ((self=[super init])) { _title=[title copy];_tfmItems=[NSMutableArray array];_autoenablesItems=YES; }return self; }
- (void)addItem:(NSMenuItem *)item { [self insertItem:item atIndex:self.tfmItems.count]; }
- (void)insertItem:(NSMenuItem *)item atIndex:(NSInteger)index { if (!item || item.menu) TFMUnsupported(self,_cmd);[self.tfmItems insertObject:item atIndex:index];item.menu=self; }
- (NSArray *)itemArray { return self.tfmItems.copy; }
- (NSInteger)numberOfItems { return self.tfmItems.count; }
- (void)removeItem:(NSMenuItem *)item { [self.tfmItems removeObjectIdenticalTo:item];item.menu=nil; }
- (NSMenuItem *)itemAtIndex:(NSInteger)index { return self.tfmItems[index]; }
+ (BOOL)isMenuBarVisible { return NO; }
+ (void)setMenuBarVisible:(BOOL)visible { fprintf(stderr,"TFM_APPKIT_MENU model-only no-desktop-menu-bar requested=%d\n",visible); }
@end

// winit 0.30.5 macos/cursor.rs constructs RGBA bitmap cursor representations,
// writes bitmapData, then gives an NSImage to NSCursor. This is not an app icon.
@interface NSBitmapImageRep : TFMAppKitObject
@property(nonatomic,strong) NSMutableData *tfmPixels;
@property(nonatomic,readonly) NSInteger pixelsWide,pixelsHigh,bytesPerRow;
- (unsigned char *)bitmapData;
- (CGImageRef)CGImage CF_RETURNS_NOT_RETAINED;
@end
@implementation NSBitmapImageRep
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bits samplesPerPixel:(NSInteger)samples hasAlpha:(BOOL)alpha isPlanar:(BOOL)planar colorSpaceName:(NSString *)space bytesPerRow:(NSInteger)rowBytes bitsPerPixel:(NSInteger)pixelBits {
    // Only the concrete nonplanar RGBA8 layout used by winit is supported.
    // Limit both dimensions and total allocation before any multiplication.
    const NSUInteger maximumBytes=64UL*1024*1024;
    if (planes || width<=0 || height<=0 || width>8192 || height>8192 || bits!=8 || samples!=4 || !alpha || planar || ![space isEqual:NSDeviceRGBColorSpace] || (pixelBits!=0 && pixelBits!=32)) return nil;
    NSUInteger minimumRow=(NSUInteger)width*4;
    if (!rowBytes) rowBytes=(NSInteger)minimumRow;
    if (rowBytes<0 || (NSUInteger)rowBytes<minimumRow || (NSUInteger)rowBytes>maximumBytes/(NSUInteger)height) return nil;
    if ((self=[super init])) {
        _pixelsWide=width;_pixelsHigh=height;_bytesPerRow=rowBytes;
        _tfmPixels=[NSMutableData dataWithLength:(NSUInteger)rowBytes*(NSUInteger)height];
        if (!_tfmPixels) return nil;
        fprintf(stderr,"TFM_APPKIT_BITMAP_RGBA size=%ldx%ld row_bytes=%ld owned_storage=1\n",(long)width,(long)height,(long)rowBytes);
    }return self;
}
- (unsigned char *)bitmapData { return self.tfmPixels.mutableBytes; }
- (NSInteger)bitsPerSample { return 8; }
- (NSInteger)samplesPerPixel { return 4; }
- (NSInteger)bitsPerPixel { return 32; }
- (BOOL)hasAlpha { return YES; }
- (BOOL)isPlanar { return NO; }
- (NSString *)colorSpaceName { return NSDeviceRGBColorSpace; }
- (CGImageRef)CGImage {
    // bitmapData is mutable by the caller. Snapshot it at image request time,
    // rather than caching a stale image or handing CG a dangling raw buffer.
    NSData *snapshot=self.tfmPixels.copy;
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)snapshot);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=provider && space?CGImageCreate((size_t)self.pixelsWide,(size_t)self.pixelsHigh,8,32,(size_t)self.bytesPerRow,space,kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast,provider,NULL,false,kCGRenderingIntentDefault):NULL;
    if (space) CGColorSpaceRelease(space);if (provider) CGDataProviderRelease(provider);
    return image?(CGImageRef)CFAutorelease(image):NULL;
}
@end
@interface NSImage : TFMAppKitObject <NSCopying>
@property(nonatomic) CGSize size;
@property(nonatomic,strong) NSMutableArray<NSBitmapImageRep *> *tfmRepresentations;
- (CGImageRef)CGImageForProposedRect:(CGRect *)rect context:(id)context hints:(NSDictionary *)hints CF_RETURNS_NOT_RETAINED;
@end
@implementation NSImage
- (instancetype)init { return [self initWithSize:CGSizeZero]; }
- (instancetype)initWithSize:(CGSize)size {
    if (!isfinite(size.width) || !isfinite(size.height) || size.width<0 || size.height<0) return nil;
    if ((self=[super init])) { _size=size;_tfmRepresentations=[NSMutableArray array]; }return self;
}
- (void)setSize:(CGSize)size {
    if (!isfinite(size.width) || !isfinite(size.height) || size.width<0 || size.height<0) TFMUnsupported(self,_cmd);
    _size=size;
}
- (void)addRepresentation:(NSBitmapImageRep *)representation {
    if (![representation isKindOfClass:NSBitmapImageRep.class]) TFMUnsupported(self,_cmd);
    [self.tfmRepresentations addObject:representation];
    if (CGSizeEqualToSize(self.size,CGSizeZero)) self.size=CGSizeMake(representation.pixelsWide,representation.pixelsHigh);
}
- (NSArray *)representations { return self.tfmRepresentations.copy; }
- (BOOL)isValid { return self.tfmRepresentations.count>0; }
- (id)copyWithZone:(NSZone *)zone {
    NSImage *copy=[[NSImage allocWithZone:zone] initWithSize:self.size];
    [copy.tfmRepresentations addObjectsFromArray:self.tfmRepresentations];return copy;
}
- (CGImageRef)CGImageForProposedRect:(CGRect *)rect context:(id)context hints:(NSDictionary *)hints {
    if (context) TFMUnsupported(self,_cmd);
    return self.tfmRepresentations.firstObject.CGImage;
}
@end

@interface NSCursor : TFMAppKitObject
@property(nonatomic,copy) NSString *tfmName;
@property(nonatomic,readonly,strong) NSImage *image;
@property(nonatomic,readonly) CGPoint hotSpot;
+ (instancetype)arrowCursor;
- (instancetype)initWithImage:(NSImage *)image hotSpot:(CGPoint)point;
@end
static NSCursor *TFMCursor;
@interface TFMBitmapCursorController : NSObject <UIGestureRecognizerDelegate,UIPointerInteractionDelegate>
@property(nonatomic,strong) UIImageView *imageView;
@property(nonatomic,strong) UIPointerInteraction *pointerInteraction;
@property(nonatomic,strong) UIHoverGestureRecognizer *hover;
@property(nonatomic,weak) UIView *host;
@property(nonatomic) CGPoint lastPoint;
@property(nonatomic) BOOL hovering;
@property(nonatomic,strong) NSCursor *activeCursor;
- (void)refresh;
@end
static TFMBitmapCursorController *TFMBitmapCursor;
static NSCursor *TFMCursorInView(NSView *view,CGPoint hostPoint,UIView *host) {
    if (view.tfmNative.hidden || !view.window || !view.window.isVisible) return nil;
    CGPoint local=[view.tfmNative convertPoint:hostPoint fromView:host];
    if (!CGRectContainsPoint(view.tfmNative.bounds,local)) return nil;
    for (NSView *child in view.tfmSubviews.reverseObjectEnumerator) {
        NSCursor *cursor=TFMCursorInView(child,hostPoint,host);if (cursor) return cursor;
    }
    if (!view.isFlipped) local.y=view.bounds.size.height-local.y;
    for (NSDictionary *record in view.tfmCursorRects.reverseObjectEnumerator)
        if (CGRectContainsPoint([record[@"rect"] CGRectValue],local)) return record[@"cursor"];
    return nil;
}
static NSCursor *TFMCursorAtPoint(CGPoint point,UIView *host) {
    // Match the actual UIKit stacking order of hosted AppKit windows, then the
    // backed view hierarchy. Do not apply one view's cursor across the scene.
    for (UIView *native in host.subviews.reverseObjectEnumerator) {
        for (NSWindow *window in TFMWindows.allObjects) {
            if (window.contentView.tfmNative!=native) continue;
            NSCursor *cursor=TFMCursorInView(window.contentView,point,host);if (cursor) return cursor;
        }
    }
    return nil;
}

// GCMouse reports physical button transitions and raw, unaccelerated deltas.
// Its SDK contract requires UIHoverGestureRecognizer for a valid cursor point;
// never integrate those deltas into an invented absolute cursor position.
@interface TFMIndirectMouseController : NSObject
@property(nonatomic,strong) GCMouse *mouse;
@property(nonatomic,strong) NSWindow *captureWindow;
@property(nonatomic,strong) NSView *captureTarget;
@property(nonatomic,weak) NSWindow *lastPointWindow;
@property(nonatomic) CGPoint lastHostPoint,lastWindowPoint;
@property(nonatomic) BOOL hovering,hasPoint;
@property(nonatomic) NSUInteger buttons;
- (void)refreshMouse;
- (void)hoverAtPoint:(CGPoint)point hovering:(BOOL)hovering;
- (void)cancelButtons;
- (void)button:(NSUInteger)button pressed:(BOOL)pressed mouse:(GCMouse *)mouse;
@end
static TFMIndirectMouseController *TFMIndirectMouse;
static BOOL TFMHostAcceptsMouse(void) {
    return TFMHostWindow && !TFMHostWindow.hidden && UIApplication.sharedApplication.applicationState==UIApplicationStateActive &&
        TFMHostWindow.windowScene.activationState==UISceneActivationStateForegroundActive;
}
static NSView *TFMMouseTarget(CGPoint point) {
    UIView *host=TFMHostWindow.rootViewController.view;
    UIView *hit=[host hitTest:point withEvent:nil];
    for (UIView *view=hit;view;view=view.superview) {
        if ([view isKindOfClass:TFMNativeView.class]) {
            NSView *owner=((TFMNativeView *)view).owner;
            if (owner.window.isVisible) return owner;
        }
    }
    return nil;
}
@implementation TFMIndirectMouseController
- (instancetype)init {
    if ((self=[super init])) {
        NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
        for (NSString *name in @[GCMouseDidConnectNotification,GCMouseDidDisconnectNotification,GCMouseDidBecomeCurrentNotification])
            [center addObserver:self selector:@selector(devicesChanged:) name:name object:nil];
        [center addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self refreshMouse];
    }
    return self;
}
- (void)detachMouse {
    [self cancelButtons];
    self.mouse.mouseInput.mouseMovedHandler=nil;
    self.mouse.mouseInput.leftButton.pressedChangedHandler=nil;
    self.mouse.mouseInput.rightButton.pressedChangedHandler=nil;
    self.mouse=nil;TFMMouseHandlersRegistered=NO;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.mouse.mouseInput.mouseMovedHandler=nil;
    self.mouse.mouseInput.leftButton.pressedChangedHandler=nil;
    self.mouse.mouseInput.rightButton.pressedChangedHandler=nil;
}
- (void)devicesChanged:(NSNotification *)notification {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self devicesChanged:notification];});return; }
    [self refreshMouse];
}
- (void)willResignActive:(NSNotification *)notification {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self willResignActive:notification];});return; }
    [self cancelButtons];self.hovering=NO;self.hasPoint=NO;TFMMouseHasActualPoint=NO;TFMMouseHovering=NO;
    TFMRecordTouchInput(@"mouse-lifecycle-inactive",0,0);
}
- (void)didBecomeActive:(NSNotification *)notification {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self didBecomeActive:notification];});return; }
    [self refreshMouse];
    TFMRecordTouchInput(@"mouse-lifecycle-active",0,0);
}
- (void)refreshMouse {
    TFMMainThread();NSArray<GCMouse *> *mice=GCMouse.mice;TFMMouseAttachedCount=mice.count;
    GCMouse *selected=GCMouse.current;
    if (![mice containsObject:selected]) selected=mice.firstObject;
    if (self.mouse!=selected) {
        [self detachMouse];self.mouse=selected;
        if (selected.mouseInput) {
            selected.handlerQueue=dispatch_get_main_queue();
            __weak TFMIndirectMouseController *weakSelf=self;__weak GCMouse *weakMouse=selected;
            selected.mouseInput.mouseMovedHandler=^(GCMouseInput *input,float deltaX,float deltaY) {
                (void)input;(void)deltaX;(void)deltaY;
                TFMIndirectMouseController *controller=weakSelf;if (!controller || controller.mouse!=weakMouse) return;
                TFMMainThread();TFMMouseMovementCallbacks++;
                if (TFMMouseMovementCallbacks<=8 || !(TFMMouseMovementCallbacks%120)) TFMRecordTouchInput(@"mouse-raw-movement-observed",0,0);
                // UIHover supplies the absolute position, including sensitivity.
                // Raw deltas alone cannot identify the UIKit cursor location.
            };
            selected.mouseInput.leftButton.pressedChangedHandler=^(GCControllerButtonInput *input,float value,BOOL pressed) {
                (void)input;(void)value;
                [weakSelf button:0 pressed:pressed mouse:weakMouse];
            };
            selected.mouseInput.rightButton.pressedChangedHandler=^(GCControllerButtonInput *input,float value,BOOL pressed) {
                (void)input;(void)value;
                [weakSelf button:1 pressed:pressed mouse:weakMouse];
            };
            TFMMouseHandlersRegistered=YES;
        }
    }
    TFMRecordTouchInput(@"mouse-lifecycle-handlers-refreshed",0,0);
}
- (void)postType:(NSUInteger)type button:(NSUInteger)button cancelled:(BOOL)cancelled {
    NSWindow *window=self.captureWindow;NSView *target=self.captureTarget;
    if (!NSApp || !window || !target) { TFMMouseDroppedCount++;return; }
    UIView *host=TFMHostWindow.rootViewController.view;
    CGPoint previousPoint=self.lastWindowPoint;BOOL samePointWindow=self.lastPointWindow==window;
    // Retain the last real event point when balancing a detached view's stream.
    if (window.contentView.tfmNative.window==TFMHostWindow) {
        CGPoint local=[window.contentView.tfmNative convertPoint:self.lastHostPoint fromView:host];
        CGPoint point=CGPointMake(local.x,window.contentView.bounds.size.height-local.y);
        self.lastWindowPoint=point;
    }
    NSEvent *event=[NSEvent new];event.type=type;event.buttonNumber=(NSInteger)button;
    event.window=window;event.windowNumber=window.windowNumber;event.tfmInputTarget=target;
    event.locationInWindow=self.lastWindowPoint;event.timestamp=NSProcessInfo.processInfo.systemUptime;
    if ((type==5 || type==6 || type==7) && samePointWindow) {
        event.deltaX=self.lastWindowPoint.x-previousPoint.x;
        event.deltaY=previousPoint.y-self.lastWindowPoint.y;
    }
    self.lastPointWindow=window;
    event.clickCount=1;event.pressure=(type==1 || type==3 || type==6 || type==7)?1:0;
    event.tfmNativeMouse=YES;event.tfmCancelled=cancelled;
    static NSInteger sequence;event.eventNumber=++sequence;
    if (type==1 || type==3) TFMMouseDownCount++;
    else if (type==2 || type==4) TFMMouseUpCount++;
    else if (type==5) TFMMouseMoveCount++;
    else if (type==6 || type==7) TFMMouseDragCount++;
    if (cancelled) TFMMouseCancelledCount++;
    [(id)NSApp postEvent:event atStart:NO];
    TFMRecordTouchInput(cancelled?@"mouse-cancel-up-posted":@"mouse-posted",type,window.windowNumber);
}
- (void)cancelButtons {
    if (self.buttons&1UL) [self postType:2 button:0 cancelled:YES];
    if (self.buttons&2UL) [self postType:4 button:1 cancelled:YES];
    self.buttons=0;TFMMousePressedButtons=0;self.captureWindow=nil;self.captureTarget=nil;
}
- (void)button:(NSUInteger)button pressed:(BOOL)pressed mouse:(GCMouse *)mouse {
    TFMMainThread();if (!mouse || mouse!=self.mouse) return;TFMMouseButtonCallbacks++;
    NSUInteger bit=1UL<<button;
    if (pressed) {
        if (self.buttons&bit) return;
        if (!TFMHostAcceptsMouse() || !NSApp || !self.hasPoint || !self.hovering) {
            TFMMouseDroppedCount++;TFMRecordTouchInput(@"mouse-lifecycle-down-without-active-hover",0,0);return;
        }
        NSView *target=self.captureTarget ?: TFMMouseTarget(self.lastHostPoint);
        if (!target) { TFMMouseDroppedCount++;TFMRecordTouchInput(@"mouse-lifecycle-down-no-game-target",0,0);return; }
        // A stream that began as UIKit indirect touch must be balanced before
        // changing delivery source. Direct finger input remains independent.
        if (target.tfmNative.tfmPrimaryTouch.type==UITouchTypeIndirectPointer)
            [target.tfmNative tfmCancelTouchAtTimestamp:NSProcessInfo.processInfo.systemUptime];
        self.captureTarget=target;self.captureWindow=target.window;self.buttons|=bit;TFMMousePressedButtons=self.buttons;
        [self postType:button==0?1:3 button:button cancelled:NO];
    } else if (self.buttons&bit) {
        self.buttons&=~bit;TFMMousePressedButtons=self.buttons;
        [self postType:button==0?2:4 button:button cancelled:NO];
        if (!self.buttons) { self.captureWindow=nil;self.captureTarget=nil; }
    } else TFMRecordTouchInput(@"mouse-lifecycle-up-without-posted-down",0,0);
}
- (void)hoverAtPoint:(CGPoint)point hovering:(BOOL)hovering {
    TFMMainThread();TFMNativeHoverSamples++;
    if (!isfinite(point.x) || !isfinite(point.y)) return;
    CGPoint previous=self.lastHostPoint;BOOL hadPoint=self.hasPoint;
    self.lastHostPoint=point;self.hasPoint=YES;self.hovering=hovering;TFMMouseHasActualPoint=YES;TFMMouseHovering=hovering;
    if (!TFMHostAcceptsMouse() || !NSApp) { if (TFMNativeHoverSamples<=8) TFMRecordTouchInput(@"mouse-lifecycle-hover-before-active-game",0,0);return; }
    if (self.buttons && (!self.captureTarget.tfmNative.window || !self.captureWindow.isVisible)) { [self cancelButtons];return; }
    if (!hovering && !self.buttons) return;
    if (hadPoint && CGPointEqualToPoint(point,previous)) return;
    NSView *target=self.captureTarget ?: TFMMouseTarget(point);
    if (!target) return;
    BOOL transient=!self.buttons;
    if (transient) { self.captureTarget=target;self.captureWindow=target.window; }
    [self postType:(self.buttons&1UL)?6:((self.buttons&2UL)?7:5) button:(self.buttons&2UL)?1:0 cancelled:NO];
    if (transient) { self.captureTarget=nil;self.captureWindow=nil; }
}
@end
static void TFMEnsureIndirectMouse(void) {
    TFMMainThread();if (!TFMIndirectMouse) TFMIndirectMouse=[TFMIndirectMouseController new];
}
static BOOL TFMIndirectMouseActive(void) { return TFMMouseHandlersRegistered && TFMHostAcceptsMouse(); }
static void TFMIndirectMouseHover(CGPoint point,BOOL hovering) { TFMEnsureIndirectMouse();[TFMIndirectMouse hoverAtPoint:point hovering:hovering]; }
static void TFMIndirectMouseViewWillDetach(UIView *view) {
    if (TFMIndirectMouse.captureTarget.tfmNative==view || TFMIndirectMouse.captureWindow.contentView.tfmNative==view) [TFMIndirectMouse cancelButtons];
}
@implementation TFMBitmapCursorController
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)first shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)second { return YES; }
- (void)hovered:(UIHoverGestureRecognizer *)hover {
    self.hovering=hover.state==UIGestureRecognizerStateBegan || hover.state==UIGestureRecognizerStateChanged;
    self.lastPoint=[hover locationInView:self.host];
    TFMIndirectMouseHover(self.lastPoint,self.hovering);
    [self refresh];
}
- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region {
    return self.activeCursor.image?UIPointerStyle.hiddenPointerStyle:nil;
}
- (void)refresh {
    TFMMainThread();NSCursor *cursor=(self.hovering?TFMCursorAtPoint(self.lastPoint,self.host):nil) ?: (TFMCursor ?: NSCursor.arrowCursor);
    self.activeCursor=cursor;NSImage *image=cursor.image;
    self.imageView.hidden=!self.hovering || !image;
    if (image) {
        CGImageRef pixels=[image CGImageForProposedRect:NULL context:nil hints:nil];
        if (!pixels) TFMUnsupported(cursor,@selector(set));
        self.imageView.image=[UIImage imageWithCGImage:pixels];
        self.imageView.frame=(CGRect){CGPointMake(self.lastPoint.x-cursor.hotSpot.x,self.lastPoint.y-cursor.hotSpot.y),image.size};
        [self.host bringSubviewToFront:self.imageView];
    }
    [self.pointerInteraction invalidate];
}
@end
static void TFMEnsureBitmapCursor(void) {
    if (TFMBitmapCursor) return;
    UIView *host=TFMHostWindow.rootViewController.view;
    if (!host.window) return;
    TFMBitmapCursor=[TFMBitmapCursorController new];TFMBitmapCursor.host=host;
    TFMBitmapCursor.imageView=[UIImageView new];TFMBitmapCursor.imageView.userInteractionEnabled=NO;
    TFMBitmapCursor.imageView.accessibilityElementsHidden=YES;TFMBitmapCursor.imageView.hidden=YES;
    [host addSubview:TFMBitmapCursor.imageView];
    TFMBitmapCursor.hover=[[UIHoverGestureRecognizer alloc] initWithTarget:TFMBitmapCursor action:@selector(hovered:)];
    TFMBitmapCursor.hover.cancelsTouchesInView=NO;TFMBitmapCursor.hover.delegate=TFMBitmapCursor;
    [host addGestureRecognizer:TFMBitmapCursor.hover];
    TFMBitmapCursor.pointerInteraction=[[UIPointerInteraction alloc] initWithDelegate:TFMBitmapCursor];
    [host addInteraction:TFMBitmapCursor.pointerInteraction];
}
static void TFMRefreshCursorRegions(void) {
    TFMMainThread();TFMEnsureBitmapCursor();[TFMBitmapCursor refresh];
}
@implementation NSCursor
+ (instancetype)arrowCursor { static NSCursor *arrow;static dispatch_once_t once;dispatch_once(&once,^{arrow=[self new];arrow.tfmName=@"UIKit default pointer";});return arrow; }
+ (instancetype)currentCursor { return (TFMBitmapCursor.hovering?TFMBitmapCursor.activeCursor:nil) ?: TFMCursor ?: self.arrowCursor; }
- (instancetype)initWithImage:(NSImage *)image hotSpot:(CGPoint)point {
    if (!image.isValid || !isfinite(point.x) || !isfinite(point.y) || point.x<0 || point.y<0 || point.x>=image.size.width || point.y>=image.size.height) return nil;
    if ((self=[super init])) { _image=image;_hotSpot=point;_tfmName=@"Owned RGBA bitmap cursor"; }
    return self;
}
- (void)set {
    TFMMainThread();if (!self.image && self!=NSCursor.arrowCursor) TFMUnsupported(self,_cmd);
    TFMCursor=self;
    if (self.image) { TFMEnsureBitmapCursor();if (!TFMBitmapCursor) TFMUnsupported(self,_cmd); }
    [TFMBitmapCursor refresh];
    fprintf(stderr,"TFM_APPKIT_CURSOR kind=%s native_hover_driven=1 app_icon_changed=0\n",self.image?"rgba-bitmap":"uikit-default");
}
@end

static uint64_t TFMTextShowRequests,TFMTextPreeditsQueued,TFMTextPreeditsDispatched,TFMTextCommitsQueued,TFMTextCommitsDispatched,TFMTextCancelsDispatched,TFMTextTasksDropped,TFMTextCancelledTasksSkipped;
static void TFMRecordTextInput(NSString *stage,NSUInteger length,BOOL visible) {
    TFMWriteDiagnostic(@"appkit-text-input.json",@{@"stage":stage,@"editor_visible":@(visible),
        @"show_requests":@(TFMTextShowRequests),@"pending_utf16_length":@(length),
        @"preedits_queued":@(TFMTextPreeditsQueued),@"preedits_dispatched":@(TFMTextPreeditsDispatched),
        @"commits_queued":@(TFMTextCommitsQueued),@"commits_dispatched":@(TFMTextCommitsDispatched),
        @"cancels_dispatched":@(TFMTextCancelsDispatched),@"detached_target_tasks_dropped":@(TFMTextTasksDropped),
        @"cancelled_session_tasks_skipped":@(TFMTextCancelledTasksSkipped),
        @"scope":@"actual user edits in an explicit UIKit insertion editor, forwarded through original winit IME handlers; no text content stored and no game-field success claim"});
}
static BOOL TFMTextTargetAttached(NSView *target,NSWindow *window) {
    return target && window && target.window==window && target.tfmNative.window==TFMHostWindow && window.isVisible;
}
static void TFMDispatchPreedit(NSView *target,NSString *text,NSRange selection) {
    // Exact original winit 0.30.5 NSTextInputClient ABI. selectedRange is UTF16.
    ((void(*)(id,SEL,id,NSRange,NSRange))objc_msgSend)(target,
        @selector(setMarkedText:selectedRange:replacementRange:),text,selection,NSMakeRange(NSNotFound,0));
}
@interface TFMTextInputSession : NSObject
@property(nonatomic) BOOL cancelled,preeditDispatched;
@end
@implementation TFMTextInputSession @end
@interface TFMTextInsertionController : NSObject <UITextFieldDelegate>
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UIView *overlay;
@property(nonatomic,strong) UITextField *editor;
@property(nonatomic,strong) UIButton *applyButton;
@property(nonatomic,strong) NSView *target;
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) TFMTextInputSession *session;
@property(nonatomic) BOOL pendingPreedit,closing;
- (BOOL)show;
- (void)cancel;
- (void)dismissCancelling:(BOOL)cancel restoreFocus:(BOOL)restore;
@end
static TFMTextInsertionController *TFMTextInsertion;
static __weak id TFMTextTapTarget;
static NSDictionary *TFMTextTapBefore;
static NSTimeInterval TFMTextTapStarted;
static uint64_t TFMTextFocusGeneration;
static BOOL TFMTextInputOverlayVisible(void) { return TFMTextInsertion.panel!=nil; }
static void TFMTextFocusCancelPending(void) {
    TFMMainThread();TFMTextFocusGeneration++;TFMTextTapTarget=nil;TFMTextTapBefore=nil;
}
static void TFMTextFocusBeforeUserTap(id target) {
    TFMMainThread();TFMTextFocusGeneration++;
    TFMTextTapTarget=target;TFMTextTapStarted=NSProcessInfo.processInfo.systemUptime;
    TFMTextTapBefore=TFMGameTextFocusSnapshot(target);
}
static void TFMTextFocusAfterUserTap(id object) {
    TFMMainThread();
    if (object!=TFMTextTapTarget || TFMTextInputOverlayVisible()) return;
    NSView *target=object;NSWindow *window=target.window;
    NSDictionary *before=TFMTextTapBefore;uint64_t generation=TFMTextFocusGeneration;
    NSTimeInterval started=TFMTextTapStarted;
    // nextEventMatchingMask drains native tasks before mouse events. Observe
    // on later run-loop ticks, after winit has consumed the actual tap and its
    // next game update has propagated engine input mode to IME allowance.
    NSTimer *timer=[NSTimer timerWithTimeInterval:0.04 repeats:YES block:^(NSTimer *tick) {
        NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-started;
        if (generation!=TFMTextFocusGeneration || elapsed>0.6 || !TFMHostAcceptsMouse() ||
            !TFMTextTargetAttached(target,window) || TFMTextInputOverlayVisible()) {
            [tick invalidate];return;
        }
        if (NSApp.tfmEvents.count) return;
        NSDictionary *after=TFMGameTextFocusSnapshot(target);
        BOOL enabled=TFMGameTextFocusHasTapAssociatedIMEEnable(before,after,target==TFMTextTapTarget,elapsed>=0 && elapsed<=0.6);
        if (enabled || elapsed>=0.55) {
            TFMWriteDiagnostic(@"appkit-text-focus.json",@{@"before":before ?: @{},@"after":after,
                @"tap_associated_enable":@(enabled),@"policy":@"Verified false-to-true engine IME mode after real tap; no field text read"});
            [tick invalidate];
        }
        if (enabled) TFMQueueNativeInputTask(^{
            if (generation!=TFMTextFocusGeneration || NSProcessInfo.processInfo.systemUptime-started>0.6 ||
                !TFMHostAcceptsMouse() || !TFMTextTargetAttached(target,window) || TFMTextInputOverlayVisible()) return;
            NSDictionary *current=TFMGameTextFocusSnapshot(target);
            if ([current[@"available"] boolValue] && [current[@"ime_allowed"] boolValue]) TFMAppKitShowTextInput();
        });
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
static void TFMTextInputGestureRequested(void) {
    TFMMainThread();TFMTextFocusGeneration++;
    // Preserve the already tested explicit insertion path when a game field
    // does not expose an IME transition; the gesture replaces the old button.
    TFMAppKitShowTextInput();
}
@implementation TFMTextInsertionController
- (instancetype)init {
    if ((self=[super init])) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)willResignActive:(NSNotification *)notification {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self willResignActive:notification];});return; }
    [self dismissCancelling:YES restoreFocus:NO];
}
- (BOOL)show {
    TFMMainThread();TFMTextShowRequests++;
    if (self.panel) { [self.editor becomeFirstResponder];return YES; }
    NSWindow *window=(NSWindow *)(TFMKeyWindow ?: TFMMainWindow);
    NSView *target=[window.firstResponder isKindOfClass:NSView.class]?window.firstResponder:window.contentView;
    if (!NSApp.tfmRunning || !TFMHostAcceptsMouse() || !TFMTextTargetAttached(target,window) ||
        ![target respondsToSelector:@selector(setMarkedText:selectedRange:replacementRange:)] ||
        ![target respondsToSelector:@selector(insertText:replacementRange:)] || ![target respondsToSelector:@selector(unmarkText)]) {
        TFMRecordTextInput(@"editor-unavailable-no-active-text-target",0,NO);return NO;
    }
    // Never take ownership of an unrelated input source's marked text.
    if ([target respondsToSelector:@selector(hasMarkedText)] && ((BOOL(*)(id,SEL))objc_msgSend)(target,@selector(hasMarkedText))) {
        TFMRecordTextInput(@"editor-unavailable-existing-composition",0,NO);return NO;
    }
    TFMTextFocusGeneration++;TFMDirectTouchCancelForTextInput();
    self.target=target;self.window=window;self.pendingPreedit=NO;self.session=[TFMTextInputSession new];
    // Keep the game's field focus stable while its insertion editor is open.
    // An actual tap outside the panel cancels rather than entering the game.
    UIView *overlay=[[UIView alloc] initWithFrame:TFMHostWindow.bounds];overlay.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    UIButton *outside=[UIButton buttonWithType:UIButtonTypeCustom];outside.frame=overlay.bounds;
    outside.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;outside.accessibilityLabel=@"글자 입력 취소";
    [outside addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];[overlay addSubview:outside];
    UIView *panel=[UIView new];panel.translatesAutoresizingMaskIntoConstraints=NO;
    panel.backgroundColor=UIColor.secondarySystemBackgroundColor;panel.layer.cornerRadius=12;
    UILabel *label=[UILabel new];label.text=@"선택한 입력칸에 입력";
    label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];label.textColor=UIColor.secondaryLabelColor;
    UITextField *editor=[UITextField new];editor.borderStyle=UITextBorderStyleRoundedRect;
    editor.placeholder=@"입력할 글자";editor.accessibilityLabel=@"게임에 추가할 글자";
    editor.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];editor.delegate=self;
    editor.returnKeyType=UIReturnKeyDone;editor.clearButtonMode=UITextFieldViewModeWhileEditing;
    editor.autocapitalizationType=UITextAutocapitalizationTypeNone;editor.autocorrectionType=UITextAutocorrectionTypeNo;
    editor.spellCheckingType=UITextSpellCheckingTypeNo;editor.smartQuotesType=UITextSmartQuotesTypeNo;editor.smartDashesType=UITextSmartDashesTypeNo;
    [editor addTarget:self action:@selector(changed:) forControlEvents:UIControlEventEditingChanged];
    [editor setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIButton *apply=[UIButton buttonWithType:UIButtonTypeSystem];[apply setTitle:@"입력" forState:UIControlStateNormal];
    [apply addTarget:self action:@selector(apply) forControlEvents:UIControlEventTouchUpInside];apply.enabled=NO;
    UIButton *cancel=[UIButton buttonWithType:UIButtonTypeSystem];[cancel setTitle:@"취소" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[editor,apply,cancel]];row.spacing=12;row.alignment=UIStackViewAlignmentCenter;
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,row]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=8;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [panel addSubview:stack];[overlay addSubview:panel];[TFMHostWindow addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:TFMHostWindow.safeAreaLayoutGuide.leadingAnchor constant:12],
        [panel.trailingAnchor constraintEqualToAnchor:TFMHostWindow.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [panel.bottomAnchor constraintEqualToAnchor:TFMHostWindow.keyboardLayoutGuide.topAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:panel.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-10],
        [editor.heightAnchor constraintEqualToConstant:44],
        [apply.widthAnchor constraintGreaterThanOrEqualToConstant:44],
        [cancel.widthAnchor constraintGreaterThanOrEqualToConstant:44]]];
    self.panel=panel;self.overlay=overlay;self.editor=editor;self.applyButton=apply;
    if (![editor becomeFirstResponder]) { [self dismissCancelling:YES restoreFocus:NO];TFMRecordTextInput(@"editor-first-responder-rejected",0,NO);return NO; }
    TFMRecordTextInput(@"editor-shown-from-user-action",0,YES);return YES;
}
- (NSRange)selection {
    UITextRange *range=self.editor.selectedTextRange;NSUInteger length=self.editor.text.length;
    if (!range) return NSMakeRange(length,0);
    NSInteger start=[self.editor offsetFromPosition:self.editor.beginningOfDocument toPosition:range.start];
    NSInteger end=[self.editor offsetFromPosition:self.editor.beginningOfDocument toPosition:range.end];
    start=MAX(0,MIN(start,(NSInteger)length));end=MAX(start,MIN(end,(NSInteger)length));
    return NSMakeRange((NSUInteger)start,(NSUInteger)(end-start));
}
- (void)changed:(UITextField *)editor {
    if (self.closing || !self.panel) return;
    NSString *text=editor.text ?: @"";NSRange selection=[self selection];self.applyButton.enabled=text.length>0;
    NSView *target=self.target;NSWindow *window=self.window;TFMTextInputSession *session=self.session;self.pendingPreedit=YES;TFMTextPreeditsQueued++;
    // The entire visible editor is pending insertion into the game until the
    // user chooses Input. Both ordinary edits and Korean marked-text updates
    // are therefore genuine provisional text relative to the game document.
    TFMQueueNativeInputTask(^{
        if (session.cancelled) { TFMTextCancelledTasksSkipped++;TFMRecordTextInput(@"cancelled-session-preedit-skipped",0,NO);return; }
        if (!TFMTextTargetAttached(target,window)) { TFMTextTasksDropped++;TFMRecordTextInput(@"preedit-dropped-detached-target",text.length,NO);return; }
        TFMDispatchPreedit(target,text,selection);session.preeditDispatched=YES;TFMTextPreeditsDispatched++;
        TFMRecordTextInput(@"actual-user-preedit-dispatched",text.length,YES);
    });
    TFMRecordTextInput(@"actual-user-preedit-queued",text.length,YES);
}
- (void)apply {
    TFMMainThread();if (!self.panel || self.closing) return;
    // Choosing Input commits the real UIKit composition before copying it.
    // UITextField supplies Korean IME, selections, deletion and Unicode edits.
    self.closing=YES;[self.editor unmarkText];NSString *text=[self.editor.text copy] ?: @"";
    if (!text.length) { self.closing=NO;self.applyButton.enabled=NO;return; }
    NSView *target=self.target;NSWindow *window=self.window;TFMTextInputSession *session=self.session;TFMTextCommitsQueued++;
    TFMQueueNativeInputTask(^{
        if (session.cancelled) { TFMTextCancelledTasksSkipped++;TFMRecordTextInput(@"cancelled-session-commit-skipped",0,NO);return; }
        if (!TFMTextTargetAttached(target,window)) { TFMTextTasksDropped++;TFMRecordTextInput(@"commit-dropped-detached-target",text.length,NO);return; }
        // Original winit only commits insertText when marked text exists.
        // Finalize the actual pending editor buffer, commit once, then clear
        // the mark and restore Ground state. No NSEvent/scancode is invented,
        // and no unsupported macOS Carbon keyboard-layout function is called.
        TFMDispatchPreedit(target,text,NSMakeRange(text.length,0));
        ((void(*)(id,SEL,id,NSRange))objc_msgSend)(target,@selector(insertText:replacementRange:),text,NSMakeRange(NSNotFound,0));
        ((void(*)(id,SEL))objc_msgSend)(target,@selector(unmarkText));session.preeditDispatched=NO;TFMTextCommitsDispatched++;
        TFMRecordTextInput(@"actual-user-insertion-committed-to-winit",text.length,NO);
    });
    self.pendingPreedit=NO;[self dismissCancelling:NO restoreFocus:YES];
    TFMRecordTextInput(@"actual-user-insertion-commit-queued",text.length,NO);
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField { (void)textField;[self apply];return NO; }
- (void)cancel { [self dismissCancelling:YES restoreFocus:YES]; }
- (void)dismissCancelling:(BOOL)cancel restoreFocus:(BOOL)restore {
    TFMMainThread();TFMTextFocusGeneration++;if (!self.panel) return;self.closing=YES;
    NSView *target=self.target;NSWindow *window=self.window;TFMTextInputSession *session=self.session;
    if (cancel) session.cancelled=YES;
    if (cancel && self.pendingPreedit) TFMQueueNativeInputTask(^{
        if (!session.preeditDispatched) return;
        if (!TFMTextTargetAttached(target,window)) { TFMTextTasksDropped++;return; }
        ((void(*)(id,SEL))objc_msgSend)(target,@selector(unmarkText));session.preeditDispatched=NO;TFMTextCancelsDispatched++;
        TFMRecordTextInput(@"pending-insertion-cancelled",0,NO);
    });
    [self.editor resignFirstResponder];self.editor.delegate=nil;[self.overlay removeFromSuperview];
    self.panel=nil;self.overlay=nil;self.editor=nil;self.applyButton=nil;self.target=nil;self.window=nil;self.session=nil;self.pendingPreedit=NO;self.closing=NO;
    if (restore && TFMHostAcceptsMouse() && TFMTextTargetAttached(target,window)) [target.tfmNative becomeFirstResponder];
    TFMRecordTextInput(cancel?@"editor-dismissed-without-commit":@"editor-dismissed-after-input",0,NO);
}
@end
BOOL TFMAppKitShowTextInput(void) {
    TFMMainThread();if (!TFMTextInsertion) TFMTextInsertion=[TFMTextInsertionController new];return [TFMTextInsertion show];
}
void TFMAppKitHideTextInput(void) { TFMMainThread();[TFMTextInsertion cancel]; }
static void TFMTextInputViewWillDetach(UIView *view) {
    if (TFMTextInsertion.target.tfmNative==view || TFMTextInsertion.window.contentView.tfmNative==view)
        [TFMTextInsertion dismissCancelling:YES restoreFocus:NO];
}

void TFMAppKitSetHostWindow(UIWindow *window) {
    TFMMainThread();if (!window.windowScene || !window.rootViewController) TFMUnsupported(window,@selector(TFMAppKitSetHostWindow));
    if (TFMHostWindow && TFMHostWindow!=window && TFMWindows.allObjects.count) TFMUnsupported(window,@selector(TFMAppKitSetHostWindow));
    TFMHostWindow=window;fprintf(stderr,"TFM_APPKIT_HOST_READY scene=1 size=%gx%g\n",window.bounds.size.width,window.bounds.size.height);fflush(stderr);
    TFMEnsureIndirectMouse();
    TFMRecordProgress(@"host-ready");
}
UIWindow *TFMAppKitGetHostWindow(void) { return TFMHostWindow; }
void TFMAppKitHostGeometryDidChange(void) {
    TFMMainThread();if (!TFMHostWindow || !NSApp.tfmRunning) return;
    TFMQueueNativeInputTask(^{
        for (NSWindow *window in TFMWindows.allObjects) {
            if (window.tfmCanvasFullscreen)
                [window setFrame:(CGRect){CGPointZero,TFMHostWindow.rootViewController.view.bounds.size} display:YES];
        }
        TFMRecordProgress(@"host-geometry-updated");
    });
}
UIView *TFMAppKitGetNativeView(id view) { TFMMainThread();return [view isKindOfClass:NSView.class]?((NSView *)view).tfmNative:nil; }
static void TFMRecordProgress(NSString *milestone) {
    // Called only from main-thread lifecycle operations. Reading NSApp directly
    // preserves the game's right to create WinitApplication as the first caller.
    NSUInteger fullscreenWindows=0;
    for (NSWindow *window in TFMWindows.allObjects) if (window.tfmCanvasFullscreen) fullscreenWindows++;
    TFMWriteDiagnostic(@"appkit-progress.json",@{@"milestone":milestone,
        @"application_class":NSApp?NSStringFromClass(object_getClass(NSApp)):@"not-created",
        @"delegate_class":NSApp.delegate?NSStringFromClass(object_getClass(NSApp.delegate)):@"not-set",
        @"host_ready":@(TFMHostWindow!=nil),@"window_count":@(TFMWindows.allObjects.count),
        @"canvas_fullscreen_window_count":@(fullscreenWindows),
        @"run_invocations":@(TFMRunInvocationCount),@"launched":@(NSApp.tfmLaunched),
        @"running":@(NSApp.tfmRunning),@"main_thread":@(NSThread.isMainThread),
        @"scope":@"startup-milestone-only-not-gameplay-proof"});
}
NSDictionary *TFMAppKitStatus(void) {
    TFMMainThread();return @{@"host_ready":@(TFMHostWindow!=nil),@"application_class":NSApp?NSStringFromClass(NSApp.class):@"not-created",
        @"window_count":@(TFMWindows.allObjects.count),@"launched":@(NSApp.tfmLaunched),@"running":@(NSApp.tfmRunning),
        @"direct_touch":TFMDirectTouchStatus(),
        @"scope":@"winit startup object model; device gesture acceptance recorded separately",
        @"limitations":@[@"single UIKit host scene/screen; no hardware display mode switching",
            @"native touch and GameController mouse buttons plus actual UIKit hover queue original winit handlers; game action not verified",
            @"tap clicks, one-finger pan scrolls, hold then move drags, two-finger tap requests keyboard; hardware keyboard key delivery remains limited",
            @"left/right pointer buttons and hover motion supported; physical mouse-wheel, auxiliary buttons and hover enter/exit events not implemented",
            @"contextual UIKit insertion editor uses verified tap-associated IME enable or explicit two-finger gesture; existing game text is not read or replaced",
            @"menu objects have no desktop presentation or actions",
            @"fullscreen fills current UIKit game canvas only; no desktop Spaces or hardware display mode change",
            @"RGBA bitmap cursor visualization follows actual UIKit hover; cursor warp/hide counts and desktop app switching unsupported",
            @"unknown messages terminate with class/selector diagnostics; optional selector introspection stays truthful"]};
}
