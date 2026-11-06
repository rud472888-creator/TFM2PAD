#include "TFMInputGesture.h"
#include <math.h>
#include <string.h>

static TFMInputActions Empty(void) {TFMInputActions result={0};return result;}
static bool Valid(double x,double y,double time) {return isfinite(x)&&isfinite(y)&&isfinite(time)&&time>=0;}
static void Add(TFMInputActions *result,TFMInputActionKind kind,double x,double y,double time,double dx,double dy,bool cancel) {
    if(result->count<4)result->actions[result->count++]=(TFMInputAction){kind,x,y,time,dx,dy,cancel};
}
static void Append(TFMInputActions *result,TFMInputActions other) {
    for(size_t i=0;i<other.count&&result->count<4;i++)result->actions[result->count++]=other.actions[i];
}
TFMInputGestureConfig TFMInputGestureDefaults(void) {
    return (TFMInputGestureConfig){8,.30,2500,90,18,7.5,1.2,.12,true};
}
void TFMInputGestureInit(TFMInputGesture *state,TFMInputGestureConfig config) {
    if(!state)return;
    TFMInputGestureConfig defaults=TFMInputGestureDefaults();
#define VALIDATE(field) if(!isfinite(config.field)||config.field<=0)config.field=defaults.field
    VALIDATE(panThreshold);VALIDATE(longPressSeconds);VALIDATE(maximumVelocity);VALIDATE(minimumCoastVelocity);
    VALIDATE(coastStopVelocity);VALIDATE(coastDecay);VALIDATE(maximumCoastSeconds);VALIDATE(maximumTickGap);
#undef VALIDATE
    memset(state,0,sizeof *state);state->config=config;
}
TFMInputActions TFMInputGestureCancel(TFMInputGesture *state,double time) {
    TFMInputActions result=Empty();if(!state)return result;
    if(!isfinite(time)||time<state->lastTime)time=state->lastTime;
    if(state->mode==TFMInputDragging)Add(&result,TFMInputMouseUp,state->lastX,state->lastY,time,0,0,true);
    else if(state->mode==TFMInputScrolling)Add(&result,TFMInputScrollCancel,state->lastX,state->lastY,time,0,0,true);
    else if(state->mode==TFMInputCoasting)Add(&result,TFMInputMomentumCancel,state->lastX,state->lastY,time,0,0,true);
    state->mode=TFMInputIdle;state->velocityX=state->velocityY=0;return result;
}
TFMInputActions TFMInputGestureBegin(TFMInputGesture *state,double x,double y,double time) {
    TFMInputActions result=Empty();if(!state||!Valid(x,y,time))return result;
    result=TFMInputGestureCancel(state,time);
    state->mode=TFMInputPending;state->startX=state->lastX=x;state->startY=state->lastY=y;
    state->startTime=state->lastTime=time;state->velocityX=state->velocityY=0;return result;
}
static void Velocity(TFMInputGesture *state,double dx,double dy,double time) {
    double dt=time-state->lastTime;
    if(dt<=0||dt>.15){state->velocityX=state->velocityY=0;return;}
    double vx=dx/dt,vy=dy/dt,speed=hypot(vx,vy);
    if(speed>state->config.maximumVelocity){double scale=state->config.maximumVelocity/speed;vx*=scale;vy*=scale;}
    state->velocityX=.45*state->velocityX+.55*vx;state->velocityY=.45*state->velocityY+.55*vy;
}
TFMInputActions TFMInputGestureMove(TFMInputGesture *state,double x,double y,double time) {
    TFMInputActions result=Empty();if(!state||!Valid(x,y,time)||time<state->lastTime)return result;
    if(state->mode!=TFMInputPending&&state->mode!=TFMInputDragging&&state->mode!=TFMInputScrolling)return result;
    double dx=x-state->lastX,dy=y-state->lastY;
    if(state->mode==TFMInputPending) {
        if(hypot(x-state->startX,y-state->startY)>=state->config.panThreshold) {
            state->mode=TFMInputScrolling;
            Add(&result,TFMInputScrollBegin,x,y,time,x-state->startX,y-state->startY,false);
            Velocity(state,dx,dy,time);
        }
    } else if(state->mode==TFMInputDragging)Add(&result,TFMInputMouseDrag,x,y,time,dx,dy,false);
    else if(dx||dy){Add(&result,TFMInputScrollChange,x,y,time,dx,dy,false);Velocity(state,dx,dy,time);}
    state->lastX=x;state->lastY=y;state->lastTime=time;return result;
}
TFMInputActions TFMInputGestureEnd(TFMInputGesture *state,double x,double y,double time) {
    TFMInputActions result=Empty();if(!state||!Valid(x,y,time)||time<state->lastTime)return result;
    if(state->mode==TFMInputPending) {
        if(hypot(x-state->startX,y-state->startY)>=state->config.panThreshold)Append(&result,TFMInputGestureMove(state,x,y,time));
        else {
            Add(&result,TFMInputMouseDown,state->startX,state->startY,state->startTime,0,0,false);
            Add(&result,TFMInputMouseUp,x,y,time,0,0,false);state->mode=TFMInputIdle;
        }
    }
    if(state->mode==TFMInputDragging){Add(&result,TFMInputMouseUp,x,y,time,0,0,false);state->mode=TFMInputIdle;}
    else if(state->mode==TFMInputScrolling) {
        if(x!=state->lastX||y!=state->lastY)Append(&result,TFMInputGestureMove(state,x,y,time));
        Add(&result,TFMInputScrollEnd,x,y,time,0,0,false);
        bool coast=state->config.coastingEnabled&&time-state->lastTime<=.08&&
            hypot(state->velocityX,state->velocityY)>=state->config.minimumCoastVelocity;
        state->mode=coast?TFMInputCoasting:TFMInputIdle;
        if(coast){state->coastStarted=state->lastTick=time;Add(&result,TFMInputMomentumBegin,x,y,time,0,0,false);}
    }
    state->lastX=x;state->lastY=y;state->lastTime=time;return result;
}
TFMInputActions TFMInputGestureAdvance(TFMInputGesture *state,double time) {
    TFMInputActions result=Empty();if(!state||!isfinite(time)||time<state->lastTime)return result;
    if(state->mode==TFMInputPending&&time-state->startTime>=state->config.longPressSeconds) {
        state->mode=TFMInputDragging;
        Add(&result,TFMInputMouseDown,state->lastX,state->lastY,time,0,0,false);
    } else if(state->mode==TFMInputCoasting) {
        double dt=time-state->lastTick;
        if(dt<=0)return result;
        if(dt>state->config.maximumTickGap)return TFMInputGestureCancel(state,time);
        double remaining=state->config.maximumCoastSeconds-(state->lastTick-state->coastStarted);
        if(dt>remaining)dt=fmax(remaining,0);
        double decay=exp(-state->config.coastDecay*dt);
        double dx=state->velocityX*(1-decay)/state->config.coastDecay,dy=state->velocityY*(1-decay)/state->config.coastDecay;
        state->velocityX*=decay;state->velocityY*=decay;state->lastTick=time;
        if(dx||dy)Add(&result,TFMInputMomentumChange,state->lastX,state->lastY,time,dx,dy,false);
        if(time-state->coastStarted>=state->config.maximumCoastSeconds||hypot(state->velocityX,state->velocityY)<state->config.coastStopVelocity) {
            Add(&result,TFMInputMomentumEnd,state->lastX,state->lastY,time,0,0,false);state->mode=TFMInputIdle;
        }
    }
    return result;
}
bool TFMInputGestureNeedsTick(const TFMInputGesture *state){return state&&(state->mode==TFMInputPending||state->mode==TFMInputCoasting);}
const char *TFMInputGestureModeName(TFMInputGestureMode mode) {
    switch(mode){case TFMInputIdle:return "idle";case TFMInputPending:return "pending";case TFMInputDragging:return "dragging";case TFMInputScrolling:return "scrolling";case TFMInputCoasting:return "coasting";}return "unknown";
}
