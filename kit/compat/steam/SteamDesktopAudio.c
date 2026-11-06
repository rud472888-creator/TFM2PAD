// Steam's desktop HAL inventory is unavailable in this iPad host. This boundary
// does not enumerate iOS hardware, activate AVAudioSession, or touch game audio.
#include <CoreAudio/AudioHardwareBase.h>
#include <string.h>

enum {
    TFMDesktopSystemObject = 1,
    TFMDesktopDevices = 'dev#',
    TFMDesktopDefaultInput = 'dIn ',
    TFMDesktopDefaultOutput = 'dOut',
    TFMDesktopDefaultSystemOutput = 'sOut'
};

static OSStatus property_size(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifier_size,
    const void *qualifier, UInt32 *size) {
    if (!address || !size || qualifier_size || qualifier)
        return kAudioHardwareIllegalOperationError;
    if (object != TFMDesktopSystemObject) return kAudioHardwareBadObjectError;
    if (address->mScope != kAudioObjectPropertyScopeGlobal || address->mElement != 0)
        return kAudioHardwareUnknownPropertyError;
    switch (address->mSelector) {
        case TFMDesktopDevices: *size = 0; return 0;
        case TFMDesktopDefaultInput:
        case TFMDesktopDefaultOutput:
        case TFMDesktopDefaultSystemOutput: *size = sizeof(AudioObjectID); return 0;
        default: return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus AudioObjectGetPropertyDataSize(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifier_size,
    const void *qualifier, UInt32 *size) {
    return property_size(object, address, qualifier_size, qualifier, size);
}

OSStatus AudioObjectGetPropertyData(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifier_size,
    const void *qualifier, UInt32 *size, void *data) {
    if (!size) return kAudioHardwareIllegalOperationError;
    UInt32 required = 0;
    OSStatus status = property_size(object, address, qualifier_size, qualifier, &required);
    if (status) return status;
    if (*size < required) { *size = required; return kAudioHardwareBadPropertySizeError; }
    if (required && !data) return kAudioHardwareIllegalOperationError;
    if (required) {
        const AudioObjectID unknown = 0; // kAudioObjectUnknown: no desktop default.
        memcpy(data, &unknown, sizeof(unknown));
    }
    *size = required;
    return 0;
}

OSStatus AudioObjectSetPropertyData(AudioObjectID object,
    const AudioObjectPropertyAddress *address, UInt32 qualifier_size,
    const void *qualifier, UInt32 size, const void *data) {
    (void)size; (void)data;
    UInt32 ignored = 0;
    OSStatus status = property_size(object, address, qualifier_size, qualifier, &ignored);
    return status ? status : kAudioHardwareUnsupportedOperationError;
}
