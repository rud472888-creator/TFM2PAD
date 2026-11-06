#import <UIKit/UIKit.h>
#include <stdint.h>

// Main-thread-only adapter. IDs identify connected UIScreen objects for this
// process lifetime; they are not hardware serials or persistent display IDs.
// Pixel dimensions represent the current UIKit surface orientation, matching
// UIScreen.bounds. This does not change physical hardware display modes.
// Mode refs follow CoreFoundation Create/Copy/Get/Retain/Release ownership.
typedef uint32_t TFMDisplayID;
typedef const void *TFMDisplayModeRef;
typedef int32_t TFMDisplayError;
enum { TFMDisplaySuccess = 0, TFMDisplayIllegalArgument = 1001 };

void TFMDisplayCompatSetWindowScene(UIWindowScene *scene);
TFMDisplayID TFMMainDisplayID(void) __asm__("_CGMainDisplayID");
TFMDisplayError TFMGetActiveDisplayList(uint32_t capacity, TFMDisplayID *displays, uint32_t *count) __asm__("_CGGetActiveDisplayList");
CGRect TFMDisplayBounds(TFMDisplayID display) __asm__("_CGDisplayBounds");
TFMDisplayModeRef TFMDisplayCopyDisplayMode(TFMDisplayID display) __asm__("_CGDisplayCopyDisplayMode");
CFArrayRef TFMDisplayCopyAllDisplayModes(TFMDisplayID display, CFDictionaryRef options) __asm__("_CGDisplayCopyAllDisplayModes");
size_t TFMDisplayModeGetPixelWidth(TFMDisplayModeRef mode) __asm__("_CGDisplayModeGetPixelWidth");
size_t TFMDisplayModeGetPixelHeight(TFMDisplayModeRef mode) __asm__("_CGDisplayModeGetPixelHeight");
double TFMDisplayModeGetRefreshRate(TFMDisplayModeRef mode) __asm__("_CGDisplayModeGetRefreshRate");
// Create-owned IO32BitDirectPixels string for this adapter's validated logical
// RGBA8 game drawable. Describes 32-bit color storage, not physical panel depth.
CFStringRef TFMDisplayModeCopyPixelEncoding(TFMDisplayModeRef mode) __asm__("_CGDisplayModeCopyPixelEncoding") CF_RETURNS_RETAINED;
TFMDisplayModeRef TFMDisplayModeRetain(TFMDisplayModeRef mode) __asm__("_CGDisplayModeRetain");
void TFMDisplayModeRelease(TFMDisplayModeRef mode) __asm__("_CGDisplayModeRelease");
size_t TFMDisplayPixelsWide(TFMDisplayID display) __asm__("_CGDisplayPixelsWide");
size_t TFMDisplayPixelsHigh(TFMDisplayID display) __asm__("_CGDisplayPixelsHigh");

// Tests are separate from raw framework symbol availability.
NSDictionary *TFMDisplayCompatSmokeTests(UIWindowScene *scene);
