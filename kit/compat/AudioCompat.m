// Original implementation; no upstream source copied.
// ABI audited against installed Apple SDK and RustAudio/cpal v0.16.0 macos/
// {mod,enumerate}.rs; coreaudio-rs0.13.0 release commit
// 93287e2f6aa302867359c04822f6ff9d1c666942 src/audio_unit/{mod,render_callback}.rs.
// Compile ONCE; both CoreAudio/AudioToolbox boundaries reexport this same dylib.
#import "AudioCompat.h"
#import <AVFAudio/AVFAudio.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/task_info.h>

enum { TFMLogicalOutput=0x54464d02,TFMSystemObject=1,
    TFMDevices='dev#',TFMDefaultOutput='dOut',TFMDefaultInput='dIn ',
    TFMStreamFormat='sfmt',TFMStreamConfiguration='slay',TFMFrameSize='fsiz',TFMFrameSizeRange='fsz#' };
typedef struct TFMUnit {
    AudioUnit unit;BOOL initialized,started;
    AURenderCallbackStruct originalCallback;
    AudioStreamBasicDescription clientFormat;
    _Atomic uint64_t callbacks,frames,nonzeroCallbacks,callbackErrors;
    _Atomic int lastCallbackStatus;
    struct TFMUnit *next;
} TFMUnit;
static pthread_mutex_t TFMAudioLock=PTHREAD_MUTEX_INITIALIZER;
static TFMUnit *TFMUnits;
static void *TFMNativeAudio;
static AudioComponent (*NativeFind)(AudioComponent,const AudioComponentDescription *);
static OSStatus (*NativeNew)(AudioComponent,AudioComponentInstance *),(*NativeDispose)(AudioComponentInstance);
static OSStatus (*NativeInitialize)(AudioUnit),(*NativeUninitialize)(AudioUnit),(*NativeStart)(AudioUnit),(*NativeStop)(AudioUnit);
static OSStatus (*NativeGet)(AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement,void *,UInt32 *);
static OSStatus (*NativeSet)(AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement,const void *,UInt32);
static _Atomic uint64_t TFMCalls,TFMErrors,TFMStarts,TFMDisposals;
static _Atomic int TFMLastStatus;
static BOOL TFMSessionActive;
static dispatch_source_t TFMAudioTimer;
static void TFMStartDiagnostics(void);
static NSMutableArray *TFMAudioOperations;
static NSDictionary *TFMLastProperty;
// Notification handlers never take TFMAudioLock: setActive may deliver them
// synchronously while a control operation holds it. No work runs on render.
static _Atomic uint64_t TFMRouteEpoch=1,TFMRouteInvalidations;
static _Atomic int TFMLastRouteEvent;
static _Atomic BOOL TFMSessionNeedsActivation,TFMInterrupted,TFMMediaServicesLost;
static NSArray *TFMSessionObservers;
static uint64_t TFMCachedRouteEpoch,TFMRouteCacheHits,TFMRouteProbes;
static AudioStreamBasicDescription TFMCachedRouteFormat;
static UInt32 TFMCachedRouteQuantum;
static double TFMCachedSessionRate,TFMCachedSessionDuration;
static NSInteger TFMCachedSessionChannels;
static OSStatus TFMLastRouteProbeStatus;
static double TFMLastRouteProbeTimestamp;
static NSMutableArray *TFMFootprintSamples;
static uint64_t TFMFootprintCurrent,TFMFootprintPeak;
static double TFMFootprintTimestamp,TFMFootprintPeakTimestamp,TFMFootprintLastAttempt,TFMFootprintLastUptime;
static kern_return_t TFMFootprintStatus=KERN_FAILURE;

static void TFMInvalidateRoute(int event) {
    atomic_store(&TFMLastRouteEvent,event);atomic_fetch_add(&TFMRouteInvalidations,1);
    atomic_fetch_add(&TFMRouteEpoch,1);
}
static void TFMObserveSession(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
        id route=[center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;TFMInvalidateRoute(1);
        }];
        id interruption=[center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSNumber *type=note.userInfo[AVAudioSessionInterruptionTypeKey];
            atomic_store(&TFMInterrupted,!type || type.unsignedIntegerValue==AVAudioSessionInterruptionTypeBegan);
            atomic_store(&TFMSessionNeedsActivation,YES);TFMInvalidateRoute(2);
        }];
        id lost=[center addObserverForName:AVAudioSessionMediaServicesWereLostNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;atomic_store(&TFMMediaServicesLost,YES);atomic_store(&TFMSessionNeedsActivation,YES);TFMInvalidateRoute(3);
        }];
        id reset=[center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;atomic_store(&TFMMediaServicesLost,NO);atomic_store(&TFMSessionNeedsActivation,YES);TFMInvalidateRoute(4);
        }];
        TFMSessionObservers=@[route,interruption,lost,reset];
    });
}

// Caller holds control lock. At most one task_info call per second and 32
// retained samples; observed peak is not a claim about an unsampled jetsam peak.
static void TFMSampleFootprint(void) {
    double uptime=NSProcessInfo.processInfo.systemUptime;
    if(TFMFootprintLastUptime && uptime-TFMFootprintLastUptime<1.0) return;
    TFMFootprintLastUptime=uptime;TFMFootprintLastAttempt=NSDate.date.timeIntervalSince1970;
    task_vm_info_data_t info={0};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    TFMFootprintStatus=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count);
    if(TFMFootprintStatus!=KERN_SUCCESS) return;
    if(count<TASK_VM_INFO_REV1_COUNT) { TFMFootprintStatus=KERN_INVALID_ARGUMENT;return; }
    TFMFootprintCurrent=info.phys_footprint;TFMFootprintTimestamp=TFMFootprintLastAttempt;
    if(!TFMFootprintPeakTimestamp || TFMFootprintCurrent>TFMFootprintPeak) { TFMFootprintPeak=TFMFootprintCurrent;TFMFootprintPeakTimestamp=TFMFootprintTimestamp; }
    if(!TFMFootprintSamples) TFMFootprintSamples=[NSMutableArray array];
    if(TFMFootprintSamples.count>=32) [TFMFootprintSamples removeObjectAtIndex:0];
    [TFMFootprintSamples addObject:@{@"timestamp_unix":@(TFMFootprintTimestamp),@"phys_footprint_bytes":@(TFMFootprintCurrent)}];
}

static BOOL TFMNativeReady(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        TFMNativeAudio=dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        if (!TFMNativeAudio) return;
        NativeFind=dlsym(TFMNativeAudio,"AudioComponentFindNext");NativeNew=dlsym(TFMNativeAudio,"AudioComponentInstanceNew");
        NativeDispose=dlsym(TFMNativeAudio,"AudioComponentInstanceDispose");NativeInitialize=dlsym(TFMNativeAudio,"AudioUnitInitialize");
        NativeUninitialize=dlsym(TFMNativeAudio,"AudioUnitUninitialize");NativeStart=dlsym(TFMNativeAudio,"AudioOutputUnitStart");
        NativeStop=dlsym(TFMNativeAudio,"AudioOutputUnitStop");NativeGet=dlsym(TFMNativeAudio,"AudioUnitGetProperty");NativeSet=dlsym(TFMNativeAudio,"AudioUnitSetProperty");
    });return NativeFind && NativeNew && NativeDispose && NativeInitialize && NativeUninitialize && NativeStart && NativeStop && NativeGet && NativeSet;
}
static OSStatus TFMResultAt(OSStatus status,const char *operation) {
    atomic_fetch_add(&TFMCalls,1);atomic_store(&TFMLastStatus,status);if (status) atomic_fetch_add(&TFMErrors,1);
    pthread_mutex_lock(&TFMAudioLock);if(!TFMAudioOperations) TFMAudioOperations=[NSMutableArray array];
    if(TFMAudioOperations.count>=16) [TFMAudioOperations removeObjectAtIndex:0];
    [TFMAudioOperations addObject:@{@"operation":@(operation),@"status":@(status)}];pthread_mutex_unlock(&TFMAudioLock);
    TFMStartDiagnostics();return status;
}
#define TFMResult(status) TFMResultAt((status),__func__)
static TFMUnit *TFMFindUnit(AudioUnit unit) { for(TFMUnit *u=TFMUnits;u;u=u->next) if(u->unit==unit) return u;return NULL; }
static OSStatus TFMSession(void) {
    if (!TFMNativeReady()) return kAudioUnitErr_Uninitialized;
    TFMObserveSession();
    if(atomic_load(&TFMInterrupted) || atomic_load(&TFMMediaServicesLost)) return kAudioUnitErr_CannotDoInCurrentContext;
    if (TFMSessionActive && !atomic_load(&TFMSessionNeedsActivation)) return noErr;
    // Clear before calling the OS so a notification during activation survives.
    atomic_store(&TFMSessionNeedsActivation,NO);TFMSessionActive=NO;TFMInvalidateRoute(5);
    NSError *error=nil;AVAudioSession *session=AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error] || ![session setActive:YES error:&error]) {
        atomic_store(&TFMSessionNeedsActivation,YES);
        return error.code?(OSStatus)error.code:kAudioUnitErr_FailedInitialization;
    }
    if(atomic_load(&TFMInterrupted) || atomic_load(&TFMMediaServicesLost) || atomic_load(&TFMSessionNeedsActivation)) return kAudioUnitErr_CannotDoInCurrentContext;
    TFMSessionActive=YES;return noErr;
}
// Caller holds control lock. Query a genuine RemoteIO native output format;
// there is no claimed mac hardware device, alternate rate list or microphone.
static OSStatus TFMRouteFormat(AudioStreamBasicDescription *format,UInt32 *quantum) {
    OSStatus status=TFMSession();if(status) return status;
    AVAudioSession *session=AVAudioSession.sharedInstance;
    double sessionRate=session.sampleRate,sessionDuration=session.IOBufferDuration;NSInteger sessionChannels=session.outputNumberOfChannels;
    uint64_t epoch=atomic_load(&TFMRouteEpoch);
    // Buffer-duration and session configuration changes need not wait for a
    // route notification. These cheap observations also guard cached quantum.
    if(TFMCachedRouteEpoch==epoch && (sessionRate!=TFMCachedSessionRate || sessionDuration!=TFMCachedSessionDuration || sessionChannels!=TFMCachedSessionChannels)) {
        TFMInvalidateRoute(6);epoch=atomic_load(&TFMRouteEpoch);
    }
    if(TFMCachedRouteEpoch==epoch) {
        *format=TFMCachedRouteFormat;if(quantum) *quantum=TFMCachedRouteQuantum;
        if(epoch!=atomic_load(&TFMRouteEpoch) || atomic_load(&TFMSessionNeedsActivation) || atomic_load(&TFMInterrupted) || atomic_load(&TFMMediaServicesLost)) return kAudioUnitErr_CannotDoInCurrentContext;
        TFMRouteCacheHits++;return noErr;
    }
    TFMRouteProbes++;TFMLastRouteProbeTimestamp=NSDate.date.timeIntervalSince1970;
    AudioComponentDescription description={kAudioUnitType_Output,kAudioUnitSubType_RemoteIO,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent component=NativeFind(NULL,&description);if(!component) return TFMLastRouteProbeStatus=kAudioUnitErr_InvalidPropertyValue;
    AudioUnit unit=NULL;status=NativeNew(component,&unit);if(status) return TFMLastRouteProbeStatus=status;
    UInt32 size=sizeof(*format);memset(format,0,sizeof(*format));
    status=NativeInitialize(unit);BOOL initialized=status==noErr;
    if(!status) status=NativeGet(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,format,&size);
    if(initialized) { OSStatus uninitialize=NativeUninitialize(unit);if(!status) status=uninitialize; }
    OSStatus disposal=NativeDispose(unit);if(!status && disposal) status=disposal;
    if (!status && (size!=sizeof(*format) || format->mFormatID!=kAudioFormatLinearPCM || !isfinite(format->mSampleRate) || format->mSampleRate<=0 || !format->mChannelsPerFrame || format->mChannelsPerFrame>8)) status=kAudioUnitErr_FormatNotSupported;
    double frames=sessionDuration*format->mSampleRate;
    if(!status && (!isfinite(frames) || frames<1 || frames>UINT32_MAX)) status=kAudioUnitErr_FailedInitialization;
    // A notification during the probe makes this result stale. Retry on the
    // next query; never spin up more native units in this call.
    if(!status && (epoch!=atomic_load(&TFMRouteEpoch) || atomic_load(&TFMSessionNeedsActivation) || atomic_load(&TFMInterrupted) || atomic_load(&TFMMediaServicesLost) ||
        sessionRate!=session.sampleRate || sessionDuration!=session.IOBufferDuration || sessionChannels!=session.outputNumberOfChannels)) status=kAudioUnitErr_CannotDoInCurrentContext;
    if(!status) {
        TFMCachedRouteFormat=*format;TFMCachedRouteQuantum=(UInt32)llround(frames);TFMCachedRouteEpoch=epoch;
        TFMCachedSessionRate=sessionRate;TFMCachedSessionDuration=sessionDuration;TFMCachedSessionChannels=sessionChannels;
        if(quantum) *quantum=TFMCachedRouteQuantum;
    }
    TFMLastRouteProbeStatus=status;return status;
}
static OSStatus TFMCopy(void *data,UInt32 *size,const void *value,UInt32 required) {
    if(!size) return kAudioHardwareIllegalOperationError;
    if(!data) { *size=required;return noErr; }
    if(*size<required) { *size=required;return kAudioHardwareBadPropertySizeError; }
    memcpy(data,value,required);*size=required;return noErr;
}
static OSStatus TFMObjectData(AudioObjectID object,const AudioObjectPropertyAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 *size,void *data) {
    if(!address || !size || qualifierSize || qualifier || address->mElement!=0) return kAudioHardwareIllegalOperationError;
    UInt32 selector=address->mSelector;
    if(object==TFMSystemObject) {
        if(address->mScope!=kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
        if(selector==TFMDefaultInput) return kAudioHardwareUnsupportedOperationError;
        if(selector==TFMDefaultOutput || selector==TFMDevices) {
            AudioStreamBasicDescription format;OSStatus status=TFMRouteFormat(&format,NULL);if(status) return status;
            UInt32 value=TFMLogicalOutput;return TFMCopy(data,size,&value,sizeof(value));
        }return kAudioHardwareUnknownPropertyError;
    }
    if(object!=TFMLogicalOutput) return kAudioHardwareBadObjectError;
    if(address->mScope!=kAudioObjectPropertyScopeGlobal && address->mScope!=kAudioObjectPropertyScopeOutput) return kAudioHardwareUnknownPropertyError;
    AudioStreamBasicDescription format;UInt32 quantum=0;OSStatus status=TFMRouteFormat(&format,&quantum);if(status) return status;
    if(selector==TFMStreamFormat) return TFMCopy(data,size,&format,sizeof(format));
    if(selector==kAudioDevicePropertyNominalSampleRate) return TFMCopy(data,size,&format.mSampleRate,sizeof(format.mSampleRate));
    if(selector==kAudioDevicePropertyAvailableNominalSampleRates) { AudioValueRange range={format.mSampleRate,format.mSampleRate};return TFMCopy(data,size,&range,sizeof(range)); }
    if(selector==TFMFrameSize) return TFMCopy(data,size,&quantum,sizeof(quantum));
    if(selector==TFMFrameSizeRange) { AudioValueRange range={quantum,quantum};return TFMCopy(data,size,&range,sizeof(range)); }
    if(selector==kAudioDevicePropertyDeviceIsAlive) { UInt32 alive=1;return TFMCopy(data,size,&alive,sizeof(alive)); }
    if(selector==kAudioObjectPropertyName) { CFStringRef name=CFSTR("UIKit current output route (logical adapter)");return TFMCopy(data,size,&name,sizeof(name)); }
    if(selector==TFMStreamConfiguration) {
        UInt32 n=(format.mFormatFlags&kAudioFormatFlagIsNonInterleaved)?format.mChannelsPerFrame:1;
        UInt32 required=(UInt32)(offsetof(AudioBufferList,mBuffers)+n*sizeof(AudioBuffer));
        if(!data) { *size=required;return noErr; }if(*size<required) { *size=required;return kAudioHardwareBadPropertySizeError; }
        memset(data,0,required);AudioBufferList *list=data;list->mNumberBuffers=n;
        for(UInt32 i=0;i<n;i++) list->mBuffers[i].mNumberChannels=n==1?format.mChannelsPerFrame:1;
        *size=required;return noErr;
    }return kAudioHardwareUnknownPropertyError;
}
OSStatus TFMAudioObjectGetPropertyData(AudioObjectID object,const AudioObjectPropertyAddress *address,UInt32 qs,const void *q,UInt32 *size,void *data) {
    if(!data) return TFMResult(kAudioHardwareIllegalOperationError);
    pthread_mutex_lock(&TFMAudioLock);OSStatus status=TFMObjectData(object,address,qs,q,size,data);
    TFMLastProperty=@{@"operation":@"HALGetPropertyData",@"logical_object":@(object),@"property":@(address?address->mSelector:0),@"status":@(status)};
    pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status);
}
OSStatus TFMAudioObjectGetPropertyDataSize(AudioObjectID object,const AudioObjectPropertyAddress *address,UInt32 qs,const void *q,UInt32 *size) {
    pthread_mutex_lock(&TFMAudioLock);OSStatus status=TFMObjectData(object,address,qs,q,size,NULL);pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status);
}
OSStatus TFMAudioObjectAddPropertyListener(AudioObjectID object,const AudioObjectPropertyAddress *address,TFMAudioObjectListener listener,void *context) {
    (void)object;(void)address;(void)listener;(void)context;return TFMResult(kAudioHardwareUnsupportedOperationError);
}
OSStatus TFMAudioObjectRemovePropertyListener(AudioObjectID object,const AudioObjectPropertyAddress *address,TFMAudioObjectListener listener,void *context) {
    (void)object;(void)address;(void)listener;(void)context;return TFMResult(kAudioHardwareUnsupportedOperationError);
}
AudioComponent TFMAudioComponentFindNext(AudioComponent previous,const AudioComponentDescription *description) {
    if(!description || !TFMNativeReady()) return NULL;AudioComponentDescription requested=*description;
    if(requested.componentType==kAudioUnitType_Output && (requested.componentSubType=='def ' || requested.componentSubType=='ahal')) requested.componentSubType=kAudioUnitSubType_RemoteIO;
    return NativeFind(previous,&requested);
}
static OSStatus TFMRender(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *data) {
    TFMUnit *u=context;OSStatus status=u->originalCallback.inputProc(u->originalCallback.inputProcRefCon,flags,time,bus,frames,data);
    atomic_fetch_add_explicit(&u->callbacks,1,memory_order_relaxed);atomic_fetch_add_explicit(&u->frames,frames,memory_order_relaxed);
    atomic_store_explicit(&u->lastCallbackStatus,status,memory_order_relaxed);if(status) atomic_fetch_add_explicit(&u->callbackErrors,1,memory_order_relaxed);
    BOOL nonzero=NO;
    if(!status && data && data->mNumberBuffers && data->mNumberBuffers<=8) {
        for(UInt32 b=0;b<data->mNumberBuffers && !nonzero;b++) {
            AudioBuffer buffer=data->mBuffers[b];if(!buffer.mData) continue;
            if((u->clientFormat.mFormatFlags&kAudioFormatFlagIsFloat) && u->clientFormat.mBitsPerChannel==32) {
                UInt32 n=MIN(buffer.mDataByteSize/sizeof(float),128U);for(UInt32 i=0;i<n;i++) { float sample;memcpy(&sample,(char *)buffer.mData+i*sizeof(float),sizeof(sample));if(isfinite(sample) && sample!=0) { nonzero=YES;break; } }
            } else if((u->clientFormat.mFormatFlags&kAudioFormatFlagIsSignedInteger) && u->clientFormat.mBitsPerChannel==16) {
                UInt32 n=MIN(buffer.mDataByteSize/sizeof(int16_t),128U);for(UInt32 i=0;i<n;i++) { int16_t sample;memcpy(&sample,(char *)buffer.mData+i*sizeof(sample),sizeof(sample));if(sample) { nonzero=YES;break; } }
            }
        }
    }
    if(nonzero) atomic_fetch_add_explicit(&u->nonzeroCallbacks,1,memory_order_relaxed);return status;
}
NSDictionary *TFMAudioCompatStatus(void) {
    pthread_mutex_lock(&TFMAudioLock);TFMSampleFootprint();NSMutableArray *units=[NSMutableArray array];
    for(TFMUnit *u=TFMUnits;u && units.count<32;u=u->next)
        [units addObject:@{@"initialized":@(u->initialized),@"started":@(u->started),@"client_rate":@(u->clientFormat.mSampleRate),@"client_channels":@(u->clientFormat.mChannelsPerFrame),
            @"callbacks":@(atomic_load(&u->callbacks)),@"frames":@(atomic_load(&u->frames)),@"callbacks_with_nonzero_pcm_in_bounded_sample":@(atomic_load(&u->nonzeroCallbacks)),
            @"callback_errors":@(atomic_load(&u->callbackErrors)),@"last_callback_status":@(atomic_load(&u->lastCallbackStatus))}];
    uint64_t epoch=atomic_load(&TFMRouteEpoch);int event=atomic_load(&TFMLastRouteEvent);
    NSArray *events=@[@"none",@"route_change",@"interruption",@"media_services_lost",@"media_services_reset",@"session_activation",@"session_configuration"];
    NSDictionary *result=@{@"pid":@(getpid()),@"timestamp_unix":@(NSDate.date.timeIntervalSince1970),
        @"session_activated":@(TFMSessionActive && !atomic_load(&TFMSessionNeedsActivation) && !atomic_load(&TFMInterrupted) && !atomic_load(&TFMMediaServicesLost)),
        @"calls":@(atomic_load(&TFMCalls)),@"errors":@(atomic_load(&TFMErrors)),@"last_status":@(atomic_load(&TFMLastStatus)),@"actual_native_starts":@(atomic_load(&TFMStarts)),@"native_disposals":@(atomic_load(&TFMDisposals)),@"units":units,
        @"recent_operations":TFMAudioOperations.copy ?: @[],@"last_property_operation":TFMLastProperty ?: @{},
        @"route_cache":@{@"epoch":@(epoch),@"cached_epoch":@(TFMCachedRouteEpoch),@"valid":@(TFMCachedRouteEpoch==epoch),
            @"hits":@(TFMRouteCacheHits),@"native_probes":@(TFMRouteProbes),@"invalidations":@(atomic_load(&TFMRouteInvalidations)),
            @"last_invalidation":(event>=0 && (NSUInteger)event<events.count)?events[event]:@"unknown",
            @"last_probe_status":@(TFMLastRouteProbeStatus),@"last_probe_timestamp_unix":@(TFMLastRouteProbeTimestamp)},
        @"memory":@{@"metric":@"TASK_VM_INFO.phys_footprint",@"available":@(TFMFootprintTimestamp>0),
            @"current_bytes":TFMFootprintTimestamp?@(TFMFootprintCurrent):(id)NSNull.null,
            @"current_timestamp_unix":TFMFootprintTimestamp?@(TFMFootprintTimestamp):(id)NSNull.null,
            @"observed_peak_bytes":TFMFootprintTimestamp?@(TFMFootprintPeak):(id)NSNull.null,
            @"observed_peak_timestamp_unix":TFMFootprintTimestamp?@(TFMFootprintPeakTimestamp):(id)NSNull.null,
            @"last_query_status":@(TFMFootprintStatus),@"last_query_timestamp_unix":@(TFMFootprintLastAttempt),
            @"sample_capacity":@32,@"minimum_sample_interval_seconds":@1,@"samples":TFMFootprintSamples.copy ?: @[]},
        @"scope":@"output-only actual RemoteIO; logical current route, no hardware identity; counters/nonzero PCM do not prove audible sound",
        @"limitations":@[@"only currently observed native rate/quantum advertised, no alternate hardware capabilities claimed",@"microphone and HAL property listeners unsupported",@"route/interruption/media-service notifications invalidate discovery cache; existing native units are not automatically rebuilt or restarted",@"memory peak is the highest successful diagnostic sample since process start, not an OS high-water mark or a jetsam limit",@"PCM never persisted; only at most128 samples per buffer inspected for nonzero aggregate"]};
    pthread_mutex_unlock(&TFMAudioLock);return result;
}
static void TFMWriteAudio(void) {
    @autoreleasepool { NSDictionary *record=TFMAudioCompatStatus();NSURL *directory=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:NULL];
        if(directory && data) [data writeToURL:[directory URLByAppendingPathComponent:@"audio-progress.json"] options:NSDataWritingAtomic error:NULL]; }
}
static void TFMStartDiagnostics(void) {
    static dispatch_once_t once;dispatch_once(&once,^{TFMAudioTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
        dispatch_source_set_timer(TFMAudioTimer,dispatch_time(DISPATCH_TIME_NOW,0),2*NSEC_PER_SEC,NSEC_PER_SEC/4);
        dispatch_source_set_event_handler(TFMAudioTimer,^{TFMWriteAudio();});dispatch_resume(TFMAudioTimer);});
}
OSStatus TFMAudioComponentInstanceNew(AudioComponent component,AudioComponentInstance *result) {
    if(!result || !TFMNativeReady()) return TFMResult(kAudioUnitErr_InvalidParameter);
    *result=NULL;
    pthread_mutex_lock(&TFMAudioLock);OSStatus status=TFMSession();AudioUnit unit=NULL;
    if(!status) status=NativeNew(component,&unit);
    if(!status) { TFMUnit *u=calloc(1,sizeof(*u));if(!u) { NativeDispose(unit);status=kAudio_MemFullError; }else { u->unit=unit;u->next=TFMUnits;TFMUnits=u;*result=unit; } }
    pthread_mutex_unlock(&TFMAudioLock);TFMStartDiagnostics();return TFMResult(status);
}
OSStatus TFMAudioUnitInitialize(AudioUnit unit) {
    pthread_mutex_lock(&TFMAudioLock);TFMUnit *u=TFMFindUnit(unit);OSStatus status=u?NativeInitialize(unit):kAudioUnitErr_InvalidParameter;
    if(!status) u->initialized=YES;pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status);
}
OSStatus TFMAudioUnitUninitialize(AudioUnit unit) {
    pthread_mutex_lock(&TFMAudioLock);TFMUnit *u=TFMFindUnit(unit);OSStatus status=u?NativeUninitialize(unit):kAudioUnitErr_InvalidParameter;
    if(!status) u->initialized=NO;pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status);
}
OSStatus TFMAudioOutputUnitStart(AudioUnit unit) {
    pthread_mutex_lock(&TFMAudioLock);TFMUnit *u=TFMFindUnit(unit);OSStatus status=u?NativeStart(unit):kAudioUnitErr_InvalidParameter;
    if(!status) { u->started=YES;atomic_fetch_add(&TFMStarts,1); }pthread_mutex_unlock(&TFMAudioLock);TFMWriteAudio();return TFMResult(status);
}
OSStatus TFMAudioOutputUnitStop(AudioUnit unit) {
    pthread_mutex_lock(&TFMAudioLock);TFMUnit *u=TFMFindUnit(unit);OSStatus status=u?NativeStop(unit):kAudioUnitErr_InvalidParameter;
    if(!status) u->started=NO;pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status);
}
OSStatus TFMAudioComponentInstanceDispose(AudioComponentInstance unit) {
    pthread_mutex_lock(&TFMAudioLock);TFMUnit **previous=&TFMUnits;while(*previous && (*previous)->unit!=unit) previous=&(*previous)->next;
    TFMUnit *u=*previous;OSStatus status=kAudioUnitErr_InvalidParameter;
    if(u) {
        // Do not release a callback context while a genuine native render may
        // still be using it. Successful stop/uninitialize precedes disposal.
        status=u->started?NativeStop(unit):noErr;if(!status) u->started=NO;
        if(!status && u->initialized) { status=NativeUninitialize(unit);if(!status) u->initialized=NO; }
        if(!status) status=NativeDispose(unit);
    }
    if(!status) { *previous=u->next;free(u);atomic_fetch_add(&TFMDisposals,1); }pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status);
}
OSStatus TFMAudioUnitGetProperty(AudioUnit unit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,void *data,UInt32 *size) {
    if(!data || !size) return TFMResult(kAudioUnitErr_InvalidParameter);
    pthread_mutex_lock(&TFMAudioLock);TFMUnit *u=TFMFindUnit(unit);OSStatus status=kAudioUnitErr_InvalidParameter;
    if(u) {
        if(property==kAudioOutputUnitProperty_CurrentDevice && scope==kAudioUnitScope_Global && element==0) { UInt32 value=TFMLogicalOutput;status=TFMCopy(data,size,&value,sizeof(value)); }
        else if((property==TFMFrameSizeRange || property==TFMFrameSize) && scope==kAudioUnitScope_Global && element==0) {
            AudioStreamBasicDescription format;UInt32 quantum;status=TFMRouteFormat(&format,&quantum);
            if(!status) { if(property==TFMFrameSize) status=TFMCopy(data,size,&quantum,sizeof(quantum));else { AudioValueRange range={quantum,quantum};status=TFMCopy(data,size,&range,sizeof(range)); } }
        }else status=NativeGet(unit,property,scope,element,data,size);
    }TFMLastProperty=@{@"operation":@"AudioUnitGetProperty",@"property":@(property),@"scope":@(scope),@"element":@(element),@"status":@(status)};
    pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status);
}
OSStatus TFMAudioUnitSetProperty(AudioUnit unit,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement element,const void *data,UInt32 size) {
    pthread_mutex_lock(&TFMAudioLock);TFMUnit *u=TFMFindUnit(unit);OSStatus status=kAudioUnitErr_InvalidParameter;
    if(!u) { pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status); }
    if(property==kAudioOutputUnitProperty_CurrentDevice) {
        UInt32 value=0;if(data && size==sizeof(value)) memcpy(&value,data,sizeof(value));
        // RemoteIO is genuinely attached to the active session's current output.
        status=(value==TFMLogicalOutput && scope==kAudioUnitScope_Global && element==0)?noErr:kAudioUnitErr_InvalidPropertyValue;
    }else if(property==TFMFrameSize) status=kAudioUnitErr_PropertyNotWritable;
    else {
        BOOL reinitialize=u->initialized && (property==kAudioUnitProperty_StreamFormat || property==kAudioUnitProperty_SetRenderCallback);
        if(u->started && reinitialize) status=kAudioUnitErr_CannotDoInCurrentContext;
        else {
            status=reinitialize?NativeUninitialize(unit):noErr;if(!status && reinitialize) u->initialized=NO;
            AURenderCallbackStruct original={0},proxy={TFMRender,u};const void *value=data;
            if(!status && property==kAudioUnitProperty_SetRenderCallback) {
                if(!data || size!=sizeof(original) || scope!=kAudioUnitScope_Input || element!=0) status=kAudioUnitErr_InvalidParameter;
                else { memcpy(&original,data,sizeof(original));if(!original.inputProc) status=kAudioUnitErr_InvalidParameter;else value=&proxy; }
            }
            if(!status) status=NativeSet(unit,property,scope,element,value,size);
            if(!status && property==kAudioUnitProperty_SetRenderCallback) u->originalCallback=original;
            if(!status && property==kAudioUnitProperty_StreamFormat && scope==kAudioUnitScope_Input && element==0 && data && size==sizeof(u->clientFormat)) memcpy(&u->clientFormat,data,size);
            if(reinitialize && !u->initialized) { OSStatus init=NativeInitialize(unit);if(!init) u->initialized=YES;if(!status) status=init; }
        }
    }TFMLastProperty=@{@"operation":@"AudioUnitSetProperty",@"property":@(property),@"scope":@(scope),@"element":@(element),@"status":@(status)};
    pthread_mutex_unlock(&TFMAudioLock);return TFMResult(status);
}
