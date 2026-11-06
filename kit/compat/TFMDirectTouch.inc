// Included by TFMAppKit.m instead of its TFMNativeView implementation.
// Host hooks declared before this include:
//   TFMTextInputGestureRequested(), TFMTextFocusBeforeUserTap(owner),
//   TFMTextFocusAfterUserTap(owner),
//   TFMTextInputOverlayVisible(). All work stays on the main thread.
#include "TFMInputGesture.h"

@interface TFMDirectTouchState : NSObject
@property(nonatomic,weak) TFMNativeView *view;
@property(nonatomic) TFMInputGesture gesture;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) UITouch *twoA,*twoB;
@property(nonatomic) CGPoint twoStartA,twoStartB;
@property(nonatomic) NSTimeInterval twoStarted;
@property(nonatomic) BOOL twoCandidate,twoValid;
@property(nonatomic) NSInteger tapCount;
@property(nonatomic) BOOL pointerStream;
@property(nonatomic) double maximumTravel;
- (instancetype)initWithView:(TFMNativeView *)view;
@end
static uint64_t TFMDirectTaps,TFMDirectScrolls,TFMDirectLongDrags,TFMDirectMomentumEvents,TFMDirectKeyboardGestures,TFMDirectWheelEvents;
static NSHashTable<TFMDirectTouchState *> *TFMDirectTouchStates;
static char TFMDirectTouchStateKey;
@interface TFMNativeView (TFMDirectTouchInternal)
- (void)tfmGestureTick;
@end
@implementation TFMDirectTouchState
- (instancetype)initWithView:(TFMNativeView *)view {
    if((self=[super init])) {
        _view=view;TFMInputGestureInit(&_gesture,TFMInputGestureDefaults());
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resignActive:)
            name:UIApplicationWillResignActiveNotification object:nil];
    }return self;
}
- (void)resignActive:(NSNotification *)notification {
    (void)notification;
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self resignActive:nil];});return;}
    [self.view tfmCancelTouchAtTimestamp:NSProcessInfo.processInfo.systemUptime];
}
- (void)dealloc {[self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
@end
static TFMDirectTouchState *TFMDirectState(TFMNativeView *view) {
    TFMDirectTouchState *state=objc_getAssociatedObject(view,&TFMDirectTouchStateKey);
    if(!state){state=[[TFMDirectTouchState alloc] initWithView:view];objc_setAssociatedObject(view,&TFMDirectTouchStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(!TFMDirectTouchStates)TFMDirectTouchStates=[NSHashTable weakObjectsHashTable];[TFMDirectTouchStates addObject:state];}
    return state;
}
static void TFMDirectTouchCancelForTextInput(void) {
    TFMMainThread();NSTimeInterval time=NSProcessInfo.processInfo.systemUptime;
    for(TFMDirectTouchState *state in TFMDirectTouchStates.allObjects)[state.view tfmCancelTouchAtTimestamp:time];
}
static uint64_t TFMDirectTouchPostedWheelEvents(void) {return TFMDirectWheelEvents;}
static NSDictionary *TFMDirectTouchStatus(void) {
    TFMInputGestureConfig config=TFMInputGestureDefaults();
    return @{@"tap_count":@(TFMDirectTaps),@"scroll_gestures":@(TFMDirectScrolls),@"long_press_drags":@(TFMDirectLongDrags),
        @"momentum_events":@(TFMDirectMomentumEvents),@"two_finger_keyboard_requests":@(TFMDirectKeyboardGestures),
        @"wheel_events_posted":@(TFMDirectWheelEvents),
        @"pan_threshold_points":@(config.panThreshold),@"long_press_seconds":@(config.longPressSeconds),
        @"maximum_momentum_seconds":@(config.maximumCoastSeconds),
        @"policy":@"tap clicks; one-finger pan scrolls; hold then move drags; two-finger tap requests text input"};
}

@implementation TFMNativeView
- (BOOL)canBecomeFirstResponder {return YES;}
- (void)drawRect:(CGRect)rect {self.owner.tfmNeedsDisplay=NO;[self.owner drawRect:rect];}
- (NSUInteger)tfmActiveTouchCount:(UIEvent *)event {
    NSUInteger active=0;
    for(UITouch *touch in [event touchesForView:self])
        if(touch.phase!=UITouchPhaseEnded&&touch.phase!=UITouchPhaseCancelled&&!(touch.type==UITouchTypeIndirectPointer&&TFMIndirectMouseActive()))active++;
    return active;
}
- (void)tfmEmitActions:(TFMInputActions)actions {
    TFMDirectTouchState *state=TFMDirectState(self);
    for(size_t i=0;i<actions.count;i++) {
        TFMInputAction action=actions.actions[i];NSWindow *window=self.tfmTouchWindow;NSView *target=self.tfmTouchTarget;
        if(!NSApp||!window||!target)continue;
        NSEvent *event=[NSEvent new];event.window=window;event.tfmInputTarget=target;
        event.locationInWindow=CGPointMake(action.x,window.contentView.bounds.size.height-action.y);
        event.timestamp=action.time;event.windowNumber=window.windowNumber;event.tfmNativeTouch=YES;
        event.modifierFlags=self.tfmLastTouchModifiers;event.buttonNumber=0;event.clickCount=MAX(state.tapCount,1);
        event.tfmCancelled=action.cancelled;event.deltaX=action.deltaX;event.deltaY=action.deltaY;
        switch(action.kind) {
            case TFMInputMouseDown:event.type=1;TFMTouchDownCount++;break;
            case TFMInputMouseDrag:event.type=6;TFMTouchDragCount++;break;
            case TFMInputMouseUp:event.type=2;TFMTouchUpCount++;break;
            default:
                TFMDirectWheelEvents++;
                event.type=22;event.hasPreciseScrollingDeltas=YES;event.isDirectionInvertedFromDevice=YES;
                // winit updates its cursor before every wheel event. Keep the
                // same list captured by the real initial touch, even if the
                // finger crosses another panel or leaves the canvas.
                event.locationInWindow=CGPointMake(state.gesture.startX,
                    window.contentView.bounds.size.height-state.gesture.startY);
                event.scrollingDeltaX=action.deltaX;event.scrollingDeltaY=action.deltaY;
                switch(action.kind) {
                    case TFMInputScrollBegin:event.phase=1;TFMDirectScrolls++;break;
                    case TFMInputScrollChange:event.phase=4;break;
                    case TFMInputScrollEnd:event.phase=8;break;
                    case TFMInputScrollCancel:event.phase=16;break;
                    case TFMInputMomentumBegin:event.momentumPhase=1;TFMDirectMomentumEvents++;break;
                    case TFMInputMomentumChange:event.momentumPhase=4;TFMDirectMomentumEvents++;break;
                    case TFMInputMomentumEnd:event.momentumPhase=8;TFMDirectMomentumEvents++;break;
                    case TFMInputMomentumCancel:event.momentumPhase=16;TFMDirectMomentumEvents++;break;
                    default:break;
                }break;
        }
        if(action.cancelled)TFMTouchCancelCount++;
        static NSInteger sequence;event.eventNumber=++sequence;self.tfmLastTouchPoint=event.locationInWindow;
        [(id)NSApp postEvent:event atStart:NO];
        TFMRecordTouchInput(@"classified-direct-touch-posted",event.type,window.windowNumber);
    }
}
- (void)tfmUpdateGestureTimer {
    TFMDirectTouchState *state=TFMDirectState(self);
    TFMInputGesture gesture=state.gesture;
    if(!TFMInputGestureNeedsTick(&gesture)){[state.timer invalidate];state.timer=nil;return;}
    if(state.timer)return;
    __weak TFMNativeView *weakSelf=self;
    state.timer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(__unused NSTimer *timer){[weakSelf tfmGestureTick];}];
    [NSRunLoop.mainRunLoop addTimer:state.timer forMode:NSRunLoopCommonModes];
}
- (void)tfmFinishCaptureIfIdle {
    TFMDirectTouchState *state=TFMDirectState(self);
    if(state.gesture.mode==TFMInputIdle&&!self.tfmPrimaryTouch){self.tfmTouchWindow=nil;self.tfmTouchTarget=nil;}
    [self tfmUpdateGestureTimer];
}
- (void)tfmGestureTick {
    TFMMainThread();TFMDirectTouchState *state=TFMDirectState(self);
    if(!self.window||!TFMHostAcceptsMouse()||TFMTextInputOverlayVisible()) {
        [self tfmCancelTouchAtTimestamp:NSProcessInfo.processInfo.systemUptime];return;
    }
    TFMInputGesture gesture=state.gesture;TFMInputGestureMode prior=gesture.mode;
    TFMInputActions actions=TFMInputGestureAdvance(&gesture,NSProcessInfo.processInfo.systemUptime);state.gesture=gesture;
    if(prior==TFMInputPending&&gesture.mode==TFMInputDragging)TFMDirectLongDrags++;
    [self tfmEmitActions:actions];[self tfmFinishCaptureIfIdle];
}
- (void)tfmCancelTouchAtTimestamp:(NSTimeInterval)timestamp {
    TFMDirectTouchState *state=TFMDirectState(self);TFMInputGesture gesture=state.gesture;
    TFMInputActions actions=TFMInputGestureCancel(&gesture,timestamp);state.gesture=gesture;
    [self tfmEmitActions:actions];self.tfmPrimaryTouch=nil;self.tfmTouchWindow=nil;self.tfmTouchTarget=nil;
    self.tfmSuppressTouches=NO;
    state.twoCandidate=NO;state.twoValid=NO;state.twoA=nil;state.twoB=nil;
    [self tfmUpdateGestureTimer];
}
- (void)tfmCheckTwoFingerMovement:(UIEvent *)event {
    TFMDirectTouchState *state=TFMDirectState(self);if(!state.twoCandidate)return;
    CGPoint a=[state.twoA locationInView:self],b=[state.twoB locationInView:self];
    if(hypot(a.x-state.twoStartA.x,a.y-state.twoStartA.y)>8||hypot(b.x-state.twoStartB.x,b.y-state.twoStartB.y)>8||
       event.timestamp-state.twoStarted>.30||[self tfmActiveTouchCount:event]>2)state.twoValid=NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    TFMMainThread();TFMRawTouchBeganEntries++;
    if(!NSApp||!self.owner.window){TFMTouchMissingOwner++;TFMRecordTouchInput(@"raw-touch-no-app-or-owner-window",0,0);return;}
    NSMutableSet<UITouch *> *accepted=[touches mutableCopy];
    for(UITouch *touch in touches)if(touch.type==UITouchTypeIndirectPointer&&TFMIndirectMouseActive()){
        [accepted removeObject:touch];TFMIndirectTouchesIgnored++;
    }
    if(!accepted.count)return;
    TFMTextFocusCancelPending();
    TFMDirectTouchState *state=TFMDirectState(self);NSUInteger active=[self tfmActiveTouchCount:event];
    if(active>1) {
        NSMutableArray<UITouch *> *pair=[NSMutableArray array];
        for(UITouch *touch in [event touchesForView:self])
            if(touch.phase!=UITouchPhaseEnded&&touch.phase!=UITouchPhaseCancelled&&!(touch.type==UITouchTypeIndirectPointer&&TFMIndirectMouseActive()))[pair addObject:touch];
        BOOL pending=state.gesture.mode==TFMInputPending;
        BOOL noClickYet=pending||(!self.tfmPrimaryTouch&&(state.gesture.mode==TFMInputIdle||state.gesture.mode==TFMInputCoasting));
        BOOL candidate=active==2&&pair.count==2&&pair[0].type==UITouchTypeDirect&&pair[1].type==UITouchTypeDirect&&
            noClickYet&&(!pending||event.timestamp-state.gesture.startTime<=.18);
        NSTimeInterval began=pending?state.gesture.startTime:event.timestamp;
        UITouch *first=self.tfmPrimaryTouch;
        CGPoint firstStart=CGPointMake(state.gesture.startX,state.gesture.startY);
        if(pending)firstStart=[self convertPoint:firstStart fromView:self.tfmTouchWindow.contentView.tfmNative];
        [self tfmCancelTouchAtTimestamp:event.timestamp];self.tfmSuppressTouches=YES;TFMTouchSuppressedCount++;
        if(candidate) {
            state.twoA=pair[0];state.twoB=pair[1];
            state.twoStartA=pair[0]==first?firstStart:[pair[0] locationInView:self];
            state.twoStartB=pair[1]==first?firstStart:[pair[1] locationInView:self];
            state.twoStarted=began;state.twoCandidate=state.twoValid=YES;
        }return;
    }
    if(self.tfmSuppressTouches||self.tfmPrimaryTouch)return;
    UITouch *touch=accepted.anyObject;if(!touch)return;
    // Finish the previous source's momentum before replacing its captured view.
    TFMInputGesture gesture=state.gesture;[self tfmEmitActions:TFMInputGestureCancel(&gesture,touch.timestamp)];
    self.tfmPrimaryTouch=touch;self.tfmTouchWindow=self.owner.window;self.tfmTouchTarget=self.owner;
    self.tfmLastTouchModifiers=(NSUInteger)event.modifierFlags;state.tapCount=(NSInteger)touch.tapCount;
    CGPoint point=[touch locationInView:self.tfmTouchWindow.contentView.tfmNative];
    (void)TFMInputGestureBegin(&gesture,point.x,point.y,touch.timestamp);state.gesture=gesture;
    state.pointerStream=touch.type!=UITouchTypeDirect;state.maximumTravel=0;
    if(state.pointerStream) {
        // Preserve mouse/trackpad fallback and pencil pointer semantics. Only
        // an actual direct finger changes immediate pans into scroll gestures.
        gesture.mode=TFMInputDragging;state.gesture=gesture;
        TFMTextFocusBeforeUserTap(self.tfmTouchTarget);
        TFMInputActions down={.count=1,.actions={{TFMInputMouseDown,point.x,point.y,touch.timestamp,0,0,false}}};
        [self tfmEmitActions:down];
    }
    [self tfmUpdateGestureTimer];TFMRecordTouchInput(@"direct-touch-pending-classification",0,self.owner.window.windowNumber);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    TFMMainThread();TFMDirectTouchState *state=TFMDirectState(self);
    if(state.twoCandidate){[self tfmCheckTwoFingerMovement:event];return;}
    if([self tfmActiveTouchCount:event]>1){[self tfmCancelTouchAtTimestamp:event.timestamp];self.tfmSuppressTouches=YES;return;}
    if(self.tfmSuppressTouches||!self.tfmPrimaryTouch||![touches containsObject:self.tfmPrimaryTouch])return;
    CGPoint point=[self.tfmPrimaryTouch locationInView:self.tfmTouchWindow.contentView.tfmNative];
    self.tfmLastTouchModifiers=(NSUInteger)event.modifierFlags;TFMInputGesture gesture=state.gesture;
    state.maximumTravel=MAX(state.maximumTravel,hypot(point.x-gesture.startX,point.y-gesture.startY));
    TFMInputActions actions=TFMInputGestureMove(&gesture,point.x,point.y,self.tfmPrimaryTouch.timestamp);state.gesture=gesture;
    [self tfmEmitActions:actions];[self tfmUpdateGestureTimer];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    TFMMainThread();TFMDirectTouchState *state=TFMDirectState(self);
    if(state.twoCandidate) {
        [self tfmCheckTwoFingerMovement:event];NSUInteger active=[self tfmActiveTouchCount:event];
        if(!active){BOOL request=state.twoValid;state.twoCandidate=state.twoValid=NO;state.twoA=nil;state.twoB=nil;
            if(request){TFMDirectKeyboardGestures++;TFMQueueNativeInputTask(^{TFMTextInputGestureRequested();});}}
        self.tfmSuppressTouches=active>0;return;
    }
    if(self.tfmPrimaryTouch&&[touches containsObject:self.tfmPrimaryTouch]) {
        UITouch *touch=self.tfmPrimaryTouch;CGPoint point=[touch locationInView:self.tfmTouchWindow.contentView.tfmNative];
        TFMInputGesture gesture=state.gesture;TFMInputActions actions=TFMInputGestureEnd(&gesture,point.x,point.y,touch.timestamp);state.gesture=gesture;
        state.maximumTravel=MAX(state.maximumTravel,hypot(point.x-gesture.startX,point.y-gesture.startY));
        NSView *owner=self.tfmTouchTarget;BOOL tap=(actions.count==2&&actions.actions[0].kind==TFMInputMouseDown&&actions.actions[1].kind==TFMInputMouseUp)||
            (state.pointerStream&&state.maximumTravel<gesture.config.panThreshold);
        if(tap&&!state.pointerStream)TFMTextFocusBeforeUserTap(owner);
        [self tfmEmitActions:actions];self.tfmPrimaryTouch=nil;
        if(tap){TFMDirectTaps++;TFMQueueNativeInputTask(^{TFMTextFocusAfterUserTap(owner);});}
        [self tfmFinishCaptureIfIdle];
    }
    self.tfmSuppressTouches=[self tfmActiveTouchCount:event]>0;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;TFMMainThread();[self tfmCancelTouchAtTimestamp:event.timestamp];self.tfmSuppressTouches=[self tfmActiveTouchCount:event]>0;
}
- (void)willMoveToWindow:(UIWindow *)window {
    if(!window){TFMIndirectMouseViewWillDetach(self);TFMTextInputViewWillDetach(self);[self tfmCancelTouchAtTimestamp:NSProcessInfo.processInfo.systemUptime];self.tfmSuppressTouches=NO;}
    [super willMoveToWindow:window];
}
@end
