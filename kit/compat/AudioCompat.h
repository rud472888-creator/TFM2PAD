// Bounded output-only macOS cpal HAL -> actual iOS RemoteIO adapter.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardwareBase.h>

typedef OSStatus (*TFMAudioObjectListener)(AudioObjectID,UInt32,const AudioObjectPropertyAddress *,void *);
OSStatus TFMAudioObjectGetPropertyData(AudioObjectID,const AudioObjectPropertyAddress *,UInt32,const void *,UInt32 *,void *) __asm__("_AudioObjectGetPropertyData");
OSStatus TFMAudioObjectGetPropertyDataSize(AudioObjectID,const AudioObjectPropertyAddress *,UInt32,const void *,UInt32 *) __asm__("_AudioObjectGetPropertyDataSize");
OSStatus TFMAudioObjectAddPropertyListener(AudioObjectID,const AudioObjectPropertyAddress *,TFMAudioObjectListener,void *) __asm__("_AudioObjectAddPropertyListener");
OSStatus TFMAudioObjectRemovePropertyListener(AudioObjectID,const AudioObjectPropertyAddress *,TFMAudioObjectListener,void *) __asm__("_AudioObjectRemovePropertyListener");
AudioComponent TFMAudioComponentFindNext(AudioComponent,const AudioComponentDescription *) __asm__("_AudioComponentFindNext");
OSStatus TFMAudioComponentInstanceNew(AudioComponent,AudioComponentInstance *) __asm__("_AudioComponentInstanceNew");
OSStatus TFMAudioComponentInstanceDispose(AudioComponentInstance) __asm__("_AudioComponentInstanceDispose");
OSStatus TFMAudioOutputUnitStart(AudioUnit) __asm__("_AudioOutputUnitStart");
OSStatus TFMAudioOutputUnitStop(AudioUnit) __asm__("_AudioOutputUnitStop");
OSStatus TFMAudioUnitInitialize(AudioUnit) __asm__("_AudioUnitInitialize");
OSStatus TFMAudioUnitUninitialize(AudioUnit) __asm__("_AudioUnitUninitialize");
OSStatus TFMAudioUnitGetProperty(AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement,void *,UInt32 *) __asm__("_AudioUnitGetProperty");
OSStatus TFMAudioUnitSetProperty(AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement,const void *,UInt32) __asm__("_AudioUnitSetProperty");
NSDictionary *TFMAudioCompatStatus(void);
