#pragma once
#import <UIKit/UIKit.h>

// Main-thread only. Call after UIKit created a scene, root controller and window.
// This library never calls UIApplicationMain or replaces the game's delegate.
FOUNDATION_EXPORT void TFMAppKitSetHostWindow(UIWindow *window);
FOUNDATION_EXPORT UIWindow *TFMAppKitGetHostWindow(void);
// Queue fullscreen geometry updates outside UIKit callbacks into the game loop.
FOUNDATION_EXPORT void TFMAppKitHostGeometryDidChange(void);
// Returns the actual UIView behind an NSView compatibility object, or nil.
// The GL bridge may attach its native drawable to this view.
FOUNDATION_EXPORT UIView *TFMAppKitGetNativeView(id appKitView);
FOUNDATION_EXPORT NSDictionary *TFMAppKitStatus(void);
// User gesture or verified tap-associated IME enable only. Presents the UIKit
// insertion editor; no existing game text is read or prefilled.
FOUNDATION_EXPORT BOOL TFMAppKitShowTextInput(void);
// Cancels the pending insertion; already committed game text is unaffected.
FOUNDATION_EXPORT void TFMAppKitHideTextInput(void);

FOUNDATION_EXPORT double NSAppKitVersionNumber;
FOUNDATION_EXPORT NSString *const NSAppearanceNameAqua;
FOUNDATION_EXPORT NSString *const NSDeviceRGBColorSpace;
FOUNDATION_EXPORT NSString *const NSFilenamesPboardType;
FOUNDATION_EXPORT NSString *const NSPasteboardTypeString;
FOUNDATION_EXPORT NSString *const NSViewFrameDidChangeNotification;
