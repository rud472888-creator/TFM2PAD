#ifndef TFM_INPUT_GESTURE_H
#define TFM_INPUT_GESTURE_H
#include <stdbool.h>
#include <stddef.h>

// Coordinates and precise scroll deltas use UIKit logical points: right/down
// positive. The host converts only event positions to AppKit window coordinates.
typedef enum {
    TFMInputIdle, TFMInputPending, TFMInputDragging, TFMInputScrolling, TFMInputCoasting
} TFMInputGestureMode;
typedef enum {
    TFMInputMouseDown, TFMInputMouseDrag, TFMInputMouseUp,
    TFMInputScrollBegin, TFMInputScrollChange, TFMInputScrollEnd, TFMInputScrollCancel,
    TFMInputMomentumBegin, TFMInputMomentumChange, TFMInputMomentumEnd, TFMInputMomentumCancel
} TFMInputActionKind;
typedef struct {
    TFMInputActionKind kind;
    double x,y,time,deltaX,deltaY;
    bool cancelled;
} TFMInputAction;
typedef struct {size_t count;TFMInputAction actions[4];} TFMInputActions;
typedef struct {
    double panThreshold,longPressSeconds,maximumVelocity,minimumCoastVelocity;
    double coastStopVelocity,coastDecay,maximumCoastSeconds,maximumTickGap;
    bool coastingEnabled;
} TFMInputGestureConfig;
typedef struct {
    TFMInputGestureConfig config;
    TFMInputGestureMode mode;
    double startX,startY,startTime,lastX,lastY,lastTime;
    double velocityX,velocityY,coastStarted,lastTick;
} TFMInputGesture;

TFMInputGestureConfig TFMInputGestureDefaults(void);
void TFMInputGestureInit(TFMInputGesture *state,TFMInputGestureConfig config);
TFMInputActions TFMInputGestureBegin(TFMInputGesture *state,double x,double y,double time);
TFMInputActions TFMInputGestureMove(TFMInputGesture *state,double x,double y,double time);
TFMInputActions TFMInputGestureEnd(TFMInputGesture *state,double x,double y,double time);
TFMInputActions TFMInputGestureCancel(TFMInputGesture *state,double time);
TFMInputActions TFMInputGestureAdvance(TFMInputGesture *state,double time);
bool TFMInputGestureNeedsTick(const TFMInputGesture *state);
const char *TFMInputGestureModeName(TFMInputGestureMode mode);
#endif
