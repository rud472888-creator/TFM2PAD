// Narrow bundle lookup adapter. All other CoreFoundation symbols are reexports
// of Apple's actual iOS framework. The returned GL bundle is a real CFBundle;
// its functions come from the explicit desktop-to-GLES compatibility backend.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

static CFBundleRef GLBundle(void) {
    static CFBundleRef bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"TFMOpenGLResources.bundle"];
        bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
    });
    return bundle;
}
static void *SystemCoreFoundation(void) {
    static void *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ library = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW | RTLD_LOCAL | RTLD_FIRST); });
    return library;
}
CFBundleRef TFMGetBundle(CFStringRef identifier) __asm__("_CFBundleGetBundleWithIdentifier");
CFBundleRef TFMGetBundle(CFStringRef identifier) {
    if (identifier && CFEqual(identifier, CFSTR("com.apple.opengl"))) return GLBundle();
    CFBundleRef (*original)(CFStringRef) = dlsym(SystemCoreFoundation(), "CFBundleGetBundleWithIdentifier");
    return original ? original(identifier) : NULL;
}
void *TFMGetFunction(CFBundleRef bundle, CFStringRef name) __asm__("_CFBundleGetFunctionPointerForName");
void *TFMGetFunction(CFBundleRef bundle, CFStringRef name) {
    if (bundle && bundle == GLBundle()) {
        char symbol[256];
        if (!name || !CFStringGetCString(name, symbol, sizeof symbol, kCFStringEncodingUTF8)) return NULL;
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TFMOpenGL.dylib"];
        void *library = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
        void *(*resolve)(const char *) = library ? dlsym(library, "TFMOpenGLGetProcAddress") : NULL;
        return resolve ? resolve(symbol) : NULL;
    }
    void *(*original)(CFBundleRef, CFStringRef) = dlsym(SystemCoreFoundation(), "CFBundleGetFunctionPointerForName");
    return original ? original(bundle, name) : NULL;
}
