// Adapted from AgePad's UIKit-backed DisplayModeCompat.m; see NOTICE.md.
#import "DisplayCompat.h"
#include <math.h>

static __weak UIWindowScene *TFMPreferredScene;
static NSMapTable<UIScreen *, NSNumber *> *TFMIdentifiers;
static NSMapTable<NSValue *, NSDictionary *> *TFMModes;
static uint32_t TFMNextIdentifier = 1;
// Exact IO32BitDirectPixels encoding used by Apple's IOGraphicsTypes.h and
// winit v0.30.5 macos/ffi.rs. The port's CAEAGLLayer uses RGBA8 color storage;
// this logical mode format says nothing about physical panel/scanout bit depth.
static const char *TFMLogicalPixelEncoding = "--------RRRRRRRRGGGGGGGGBBBBBBBB";

static BOOL TFMOnMainThread(void) { return NSThread.isMainThread; }

// nativeBounds is commonly portrait even when bounds is landscape. Our display
// coordinate contract describes the current UIKit surface, so orient those real
// native dimensions to match bounds without changing any physical display mode.
static CGSize TFMCurrentSurfacePixels(CGSize points, CGSize rawNativePixels) {
    if (points.width <= 0 || points.height <= 0 || rawNativePixels.width <= 0 || rawNativePixels.height <= 0)
        return CGSizeZero;
    BOOL pointLandscape = points.width > points.height;
    BOOL nativeLandscape = rawNativePixels.width > rawNativePixels.height;
    if (points.width != points.height && rawNativePixels.width != rawNativePixels.height && pointLandscape != nativeLandscape)
        return CGSizeMake(rawNativePixels.height, rawNativePixels.width);
    return rawNativePixels;
}

void TFMDisplayCompatSetWindowScene(UIWindowScene *scene) {
    if (TFMOnMainThread()) TFMPreferredScene = scene;
}

static NSArray<UIScreen *> *TFMActiveScreens(void) {
    if (!TFMOnMainThread()) return nil;
    UIScreen *primary = TFMPreferredScene.screen ?: UIScreen.mainScreen;
    NSMutableArray *screens = [NSMutableArray array];
    if (primary) [screens addObject:primary];
    for (UIScreen *screen in UIScreen.screens)
        if (![screens containsObject:screen]) [screens addObject:screen];
    return screens;
}

static TFMDisplayID TFMIdentifier(UIScreen *screen) {
    if (!screen || !TFMOnMainThread()) return 0;
    if (!TFMIdentifiers) TFMIdentifiers = [NSMapTable weakToStrongObjectsMapTable];
    NSNumber *identifier = [TFMIdentifiers objectForKey:screen];
    if (!identifier) {
        if (TFMNextIdentifier == UINT32_MAX) return 0;
        identifier = @(TFMNextIdentifier++);
        [TFMIdentifiers setObject:identifier forKey:screen];
    }
    return identifier.unsignedIntValue;
}

static UIScreen *TFMScreen(TFMDisplayID display) {
    if (!display || !TFMOnMainThread()) return nil;
    for (UIScreen *screen in TFMActiveScreens())
        if (TFMIdentifier(screen) == display) return screen;
    return nil;
}

TFMDisplayID TFMMainDisplayID(void) { return TFMIdentifier(TFMActiveScreens().firstObject); }

TFMDisplayError TFMGetActiveDisplayList(uint32_t capacity, TFMDisplayID *displays, uint32_t *count) {
    if (count) *count = 0;
    if (!TFMOnMainThread() || !count || (!displays && capacity != 0)) return TFMDisplayIllegalArgument;
    NSArray *screens = TFMActiveScreens();
    if (!displays) {
        *count = (uint32_t)screens.count;
        return TFMDisplaySuccess;
    }
    uint32_t written = MIN(capacity, (uint32_t)screens.count);
    for (uint32_t i = 0; i < written; i++) displays[i] = TFMIdentifier(screens[i]);
    *count = written;
    return TFMDisplaySuccess;
}

CGRect TFMDisplayBounds(TFMDisplayID display) {
    UIScreen *screen = TFMScreen(display);
    return screen ? screen.bounds : CGRectZero;
}
size_t TFMDisplayPixelsWide(TFMDisplayID display) {
    UIScreen *screen = TFMScreen(display);
    return screen ? (size_t)TFMCurrentSurfacePixels(screen.bounds.size, screen.nativeBounds.size).width : 0;
}
size_t TFMDisplayPixelsHigh(TFMDisplayID display) {
    UIScreen *screen = TFMScreen(display);
    return screen ? (size_t)TFMCurrentSurfacePixels(screen.bounds.size, screen.nativeBounds.size).height : 0;
}

// Weak values permit normal CF ownership, including CFArray's own retain, to
// control lifetime. We validate pointer identity before bridging/dereferencing
// an opaque caller-supplied reference. This also rejects a foreign NSDictionary.
static NSDictionary *TFMModeObject(TFMDisplayModeRef mode) {
    if (!mode || !TFMOnMainThread()) return nil;
    return [TFMModes objectForKey:[NSValue valueWithPointer:mode]];
}

TFMDisplayModeRef TFMDisplayCopyDisplayMode(TFMDisplayID display) {
    UIScreen *screen = TFMScreen(display);
    if (!screen) return NULL;
    if (!TFMModes) TFMModes = [NSMapTable strongToWeakObjectsMapTable];
    CGSize rawNativePixels = screen.nativeBounds.size;
    CGSize pixels = TFMCurrentSurfacePixels(screen.bounds.size, rawNativePixels);
    NSDictionary *mode = @{@"TFMUIKitMode": @YES, @"display_id": @(display),
        @"pixel_width": @((size_t)pixels.width), @"pixel_height": @((size_t)pixels.height),
        @"raw_native_pixel_width": @(rawNativePixels.width), @"raw_native_pixel_height": @(rawNativePixels.height),
        @"coordinate_contract": @"Current UIKit surface orientation, matching UIScreen.bounds; physical display mode unchanged",
        @"point_width": @(screen.bounds.size.width), @"point_height": @(screen.bounds.size.height),
        @"logical_color_storage": @"RGBA8 game drawable, 32 bits per pixel; physical panel depth unreported",
        @"maximum_frames_per_second": @(screen.maximumFramesPerSecond),
        // UIKit exposes a maximum frame capability, not a fixed current scanout
        // frequency (especially on ProMotion). 0 means unspecified/unknown.
        @"refresh_rate": @0};
    TFMDisplayModeRef ref = CFBridgingRetain(mode);
    [TFMModes setObject:mode forKey:[NSValue valueWithPointer:ref]];
    return ref;
}

CFArrayRef TFMDisplayCopyAllDisplayModes(TFMDisplayID display, CFDictionaryRef options) {
    if (!TFMOnMainThread()) return NULL;
    // No hardware mode switching support; only the current UIKit surface is
    // advertised. Nonempty options have no implementation and fail explicitly.
    if (options && CFDictionaryGetCount(options) != 0) return NULL;
    TFMDisplayModeRef mode = TFMDisplayCopyDisplayMode(display);
    if (!mode) return NULL;
    CFArrayRef modes = CFArrayCreate(NULL, &mode, 1, &kCFTypeArrayCallBacks);
    TFMDisplayModeRelease(mode);
    return modes;
}

size_t TFMDisplayModeGetPixelWidth(TFMDisplayModeRef mode) { return [TFMModeObject(mode)[@"pixel_width"] unsignedLongValue]; }
size_t TFMDisplayModeGetPixelHeight(TFMDisplayModeRef mode) { return [TFMModeObject(mode)[@"pixel_height"] unsignedLongValue]; }
double TFMDisplayModeGetRefreshRate(TFMDisplayModeRef mode) { return [TFMModeObject(mode)[@"refresh_rate"] doubleValue]; }
CFStringRef TFMDisplayModeCopyPixelEncoding(TFMDisplayModeRef mode) {
    if (!TFMModeObject(mode)) return NULL;
    // Allocate an independent Create-owned string, rather than returning a
    // borrowed mode field. The caller may release the mode before the string.
    return CFStringCreateWithCString(kCFAllocatorDefault,TFMLogicalPixelEncoding,kCFStringEncodingASCII);
}
TFMDisplayModeRef TFMDisplayModeRetain(TFMDisplayModeRef mode) {
    if (!TFMModeObject(mode)) return NULL;
    return CFRetain(mode);
}
void TFMDisplayModeRelease(TFMDisplayModeRef mode) {
    if (TFMModeObject(mode)) CFRelease(mode);
}

static NSDictionary *TFMTest(NSString *name, BOOL pass, NSString *detail) {
    return @{@"name": name, @"status": pass ? @"pass" : @"fail", @"detail": detail};
}

static NSDictionary *TFMOrientationFixture(NSString *name, CGSize points, CGSize rawNative, CGSize expected) {
    CGSize actual = TFMCurrentSurfacePixels(points, rawNative);
    return @{@"name": name, @"status": CGSizeEqualToSize(actual, expected) ? @"pass" : @"fail",
        @"point_width": @(points.width), @"point_height": @(points.height),
        @"raw_native_pixel_width": @(rawNative.width), @"raw_native_pixel_height": @(rawNative.height),
        @"expected_pixel_width": @(expected.width), @"expected_pixel_height": @(expected.height),
        @"actual_pixel_width": @(actual.width), @"actual_pixel_height": @(actual.height)};
}

NSDictionary *TFMDisplayCompatSmokeTests(UIWindowScene *scene) {
    if (!TFMOnMainThread()) return @{@"status": @"fail", @"reason": @"Tests require the main thread"};
    TFMDisplayCompatSetWindowScene(scene);
    UIScreen *screen = scene.screen ?: UIScreen.mainScreen;
    TFMDisplayID display = TFMMainDisplayID();
    CGRect bounds = TFMDisplayBounds(display);
    CGSize rawNativePixels = screen.nativeBounds.size;
    CGSize pixels = TFMCurrentSurfacePixels(screen.bounds.size, rawNativePixels);
    NSMutableArray *tests = [NSMutableArray array];
    [tests addObject:TFMTest(@"scene_screen_geometry", display != 0 && CGRectEqualToRect(bounds, screen.bounds) && TFMDisplayPixelsWide(display) == (size_t)pixels.width && TFMDisplayPixelsHigh(display) == (size_t)pixels.height, @"Bounds in UIKit points; native pixel dimensions oriented to current UIKit surface")];
    double returnedPixelWidth = TFMDisplayPixelsWide(display), returnedPixelHeight = TFMDisplayPixelsHigh(display);
    BOOL matchingAspect = bounds.size.height > 0 && returnedPixelHeight > 0 && fabs(bounds.size.width / bounds.size.height - returnedPixelWidth / returnedPixelHeight) < 0.000001;
    [tests addObject:TFMTest(@"surface_point_pixel_aspect_matches", matchingAspect, @"Returned pixel aspect matches the UIKit bounds coordinate orientation")];
    NSArray *fixtures = @[
        TFMOrientationFixture(@"ipad_landscape_with_portrait_native_bounds", CGSizeMake(1376, 1032), CGSizeMake(2064, 2752), CGSizeMake(2752, 2064)),
        TFMOrientationFixture(@"ipad_portrait_with_portrait_native_bounds", CGSizeMake(1032, 1376), CGSizeMake(2064, 2752), CGSizeMake(2064, 2752)),
        TFMOrientationFixture(@"landscape_native_already_matches", CGSizeMake(1024, 768), CGSizeMake(2048, 1536), CGSizeMake(2048, 1536)),
        TFMOrientationFixture(@"portrait_with_landscape_native_bounds", CGSizeMake(768, 1024), CGSizeMake(2048, 1536), CGSizeMake(1536, 2048)),
        TFMOrientationFixture(@"invalid_zero_surface", CGSizeZero, CGSizeMake(2064, 2752), CGSizeZero)
    ];
    BOOL fixturesPass = YES;
    for (NSDictionary *fixture in fixtures) if (![fixture[@"status"] isEqual:@"pass"]) fixturesPass = NO;
    [tests addObject:@{@"name": @"surface_orientation_helper_fixtures", @"status": fixturesPass ? @"pass" : @"fail", @"detail": @"Known landscape/portrait inputs verify swapping, preservation, and invalid-size behavior", @"cases": fixtures}];
    TFMDisplayModeRef mode = TFMDisplayCopyDisplayMode(display);
    [tests addObject:TFMTest(@"mode_snapshot_geometry", mode && TFMDisplayModeGetPixelWidth(mode) == (size_t)pixels.width && TFMDisplayModeGetPixelHeight(mode) == (size_t)pixels.height, @"Retained mode snapshot uses native pixels in current UIKit surface orientation")];
    TFMDisplayModeRef retained = TFMDisplayModeRetain(mode);
    TFMDisplayModeRelease(mode);
    BOOL retainedValid = retained && TFMDisplayModeGetPixelWidth(retained) == (size_t)pixels.width;
    [tests addObject:TFMTest(@"mode_retain_release", retainedValid, @"Retained mode remains readable after releasing original ownership")];
    [tests addObject:TFMTest(@"refresh_rate_unspecified", TFMDisplayModeGetRefreshRate(retained) == 0, @"0 means unknown; maximumFramesPerSecond is not claimed as current scanout frequency")];
    CFStringRef encoding = TFMDisplayModeCopyPixelEncoding(retained);
    CFStringRef secondEncoding = TFMDisplayModeCopyPixelEncoding(retained);
    BOOL encodingValid = encoding && secondEncoding && CFGetTypeID(encoding) == CFStringGetTypeID() && CFStringCompare(encoding,CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB"),0) == kCFCompareEqualTo && CFEqual(encoding,secondEncoding);
    [tests addObject:TFMTest(@"logical_rgba8_pixel_encoding", encodingValid, @"Create-owned IO32BitDirectPixels string matches winit's 32-bit parser; describes logical RGBA8 storage, not panel depth")];
    TFMDisplayModeRelease(retained);
    if (encoding) CFRelease(encoding);
    BOOL encodingLifetime = secondEncoding && CFStringCompare(secondEncoding,CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB"),0) == kCFCompareEqualTo;
    [tests addObject:TFMTest(@"pixel_encoding_copy_ownership", encodingValid && encodingLifetime, @"Second owned encoding remains valid after releasing the mode and first encoding; each copy is released independently")];
    if (secondEncoding) CFRelease(secondEncoding);
    uint32_t total = 0;
    BOOL counted = TFMGetActiveDisplayList(0, NULL, &total) == TFMDisplaySuccess && total > 0;
    NSMutableData *ids = [NSMutableData dataWithLength:MAX((NSUInteger)total, 1) * sizeof(TFMDisplayID)];
    uint32_t written = 0;
    BOOL enumerated = TFMGetActiveDisplayList(total, ids.mutableBytes, &written) == TFMDisplaySuccess;
    BOOL containsMain = NO;
    TFMDisplayID *list = ids.mutableBytes;
    for (uint32_t i = 0; i < written; i++) if (list[i] == display) containsMain = YES;
    [tests addObject:TFMTest(@"active_display_enumeration", counted && enumerated && written == total && containsMain, @"Count query and bounded enumeration agree; primary display included")];
    uint32_t truncated = UINT32_MAX;
    BOOL noWrite = TFMGetActiveDisplayList(0, list, &truncated) == TFMDisplaySuccess && truncated == 0;
    [tests addObject:TFMTest(@"enumeration_zero_capacity", noWrite, @"Zero capacity writes no display IDs")];
    CFArrayRef modes = TFMDisplayCopyAllDisplayModes(display, NULL);
    BOOL modesValid = modes && CFArrayGetCount(modes) == 1;
    if (modesValid) modesValid = TFMDisplayModeGetPixelWidth(CFArrayGetValueAtIndex(modes, 0)) == (size_t)pixels.width;
    [tests addObject:TFMTest(@"current_mode_enumeration_ownership", modesValid, @"Only current surface advertised; array retains readable mode")];
    if (modes) CFRelease(modes);
    NSDictionary *unsupportedOptions = @{@"unsupported": @YES};
    BOOL invalid = CGRectEqualToRect(TFMDisplayBounds(UINT32_MAX), CGRectZero) && TFMDisplayPixelsWide(UINT32_MAX) == 0 && TFMDisplayPixelsHigh(UINT32_MAX) == 0 && !TFMDisplayCopyDisplayMode(UINT32_MAX) && !TFMDisplayCopyAllDisplayModes(UINT32_MAX, NULL) && !TFMDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)unsupportedOptions);
    [tests addObject:TFMTest(@"invalid_displays_and_options", invalid, @"Unknown display and unimplemented enumeration options fail")];
    BOOL invalidMode = TFMDisplayModeGetPixelWidth(NULL) == 0 && TFMDisplayModeGetPixelHeight((const void *)(uintptr_t)1) == 0 && TFMDisplayModeGetRefreshRate(NULL) == 0 && !TFMDisplayModeRetain((const void *)(uintptr_t)1) && !TFMDisplayModeCopyPixelEncoding(NULL) && !TFMDisplayModeCopyPixelEncoding((const void *)(uintptr_t)1);
    TFMDisplayModeRelease(NULL);
    TFMDisplayModeRelease((const void *)(uintptr_t)1);
    uint32_t invalidCount = UINT32_MAX;
    BOOL invalidList = TFMGetActiveDisplayList(1, NULL, &invalidCount) == TFMDisplayIllegalArgument && invalidCount == 0 && TFMGetActiveDisplayList(1, list, NULL) == TFMDisplayIllegalArgument;
    [tests addObject:TFMTest(@"invalid_mode_refs_and_output_arguments", invalidMode && invalidList, @"Null/foreign mode pointers and invalid enumeration arguments are rejected")];
    __block BOOL workerRejected = NO;
    TFMDisplayModeRef workerMode = TFMDisplayCopyDisplayMode(display);
    BOOL workerHadMode = workerMode != NULL;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        uint32_t count = UINT32_MAX;
        workerRejected = TFMMainDisplayID() == 0 && TFMGetActiveDisplayList(0, NULL, &count) == TFMDisplayIllegalArgument && count == 0 && !TFMDisplayCopyDisplayMode(display) && !TFMDisplayModeCopyPixelEncoding(workerMode);
        dispatch_semaphore_signal(finished);
    });
    BOOL workerFinished = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    TFMDisplayModeRelease(workerMode);
    [tests addObject:TFMTest(@"background_thread_rejected", workerHadMode && workerFinished && workerRejected, @"Adapter does not access UIKit off the main thread; owned valid mode pixel-encoding query is also rejected")];
    NSUInteger passed = 0;
    for (NSDictionary *test in tests) if ([test[@"status"] isEqual:@"pass"]) passed++;
    return @{@"status": passed == tests.count ? @"pass" : @"fail", @"passed": @(passed), @"failed": @(tests.count - passed), @"tests": tests,
        @"geometry": @{@"display_id": @(display), @"point_width": @(bounds.size.width), @"point_height": @(bounds.size.height), @"pixel_width": @(pixels.width), @"pixel_height": @(pixels.height), @"raw_native_pixel_width": @(rawNativePixels.width), @"raw_native_pixel_height": @(rawNativePixels.height), @"maximum_frames_per_second": @(screen.maximumFramesPerSecond), @"coordinate_contract": @"Current UIKit surface orientation; raw_native fields preserve original UIScreen.nativeBounds observation"},
        @"limitations": @[@"Main-thread-only; IDs identify connected screens for this process lifetime.", @"Current UIKit surface only; pixel dimensions match its bounds orientation and do not imply a changed physical hardware mode.", @"IO32BitDirectPixels describes the port's RGBA8 32-bit game drawable, not physical panel or scanout bit depth.", @"Hardware mode switching is not implemented.", @"Refresh rate is 0 (unknown); maximum frame capability is recorded separately.", @"Self-tests do not establish original game rendering or a complete playable port."]};
}
