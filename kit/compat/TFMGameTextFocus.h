#import <Foundation/Foundation.h>

// Main thread; caller supplies a valid original WinitView object, not its UIKit
// backing view. Only bounded native memory reads and Objective-C runtime queries
// are used. No original selector, setter or Rust function is invoked.
// IME allowance reflects engine input mode, not proven text-field focus.
FOUNDATION_EXPORT NSDictionary *TFMGameTextFocusSnapshot(id originalWinitView);

// Pure observation rule, not permission to present a keyboard: both snapshots
// must be verified, from the same native view, and straddle a recent user tap.
// An initially/always allowed view never produces an enable transition.
// Actual field/nonfield tap behavior must be validated on the device first.
FOUNDATION_EXPORT BOOL TFMGameTextFocusHasTapAssociatedIMEEnable(NSDictionary *before,
    NSDictionary *after,BOOL sameNativeView,BOOL recentUserTap);

#ifdef TFM_GAME_TEXT_FOCUS_TESTING
// Synthetic byte-buffer bounds tests only; absent from production exports.
NSDictionary *TFMGameTextFocusTestRead(const void *bytes,size_t instanceSize,
    size_t superclassSize,uint64_t ivarOffset,BOOL profileVerified);
#endif
