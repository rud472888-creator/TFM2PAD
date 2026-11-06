#import "GameLoaderProbe.h"
#import "SteamGameCoordinator.h"
#import "SteamSDKBoundaryHost.h"
#import "../compat/steam/SteamLaunchPolicy.h"
#import "../compat/GLSurface.h"
#import "../compat/GL4ESRenderProbe.h"
#import <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

extern NSDictionary *TFMPrepareCommunityMods(NSURL *documents);

static void SaveProgress(NSDictionary *report) {
    NSURL *dir = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    [data writeToURL:[dir URLByAppendingPathComponent:@"game-loader-progress.json"] atomically:YES];
}

typedef struct { void *gles; void *(*desktopResolver)(const char *); __unsafe_unretained NSMutableArray *lookups; } LookupContext;
static void *driverLibrary;
static int backingWidth, backingHeight;
static void *DriverProc(const char *name) { return name ? dlsym(driverLibrary, name) : NULL; }
static void BackingSize(int *w, int *h) { *w = backingWidth; *h = backingHeight; }
static const void *GetGLProc(void *opaque, const char *name) {
    LookupContext *context = opaque;
    if (!name || strncmp(name, "gl", 2)) return NULL;
    void *address = context->desktopResolver ? context->desktopResolver(name) : dlsym(context->gles, name);
    [context->lookups addObject:@{@"name": @(name), @"available": @(address != NULL)}];
    return address;
}

NSDictionary *TFMGameLoaderProbe(UIView *host) {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TeamfightManager2.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return @{@"status": @"not_bundled", @"game_main_called": @NO};
    NSMutableDictionary *report = [@{@"status": @"starting", @"game_main_called": @NO,
        @"scope": @"Load original adapted game image and call its existing Skia C entrypoints against real GLES. No game main, save, assets or Steam login.",
        @"abi_source": @"https://github.com/rust-skia/rust-skia/blob/0.87.0/skia-bindings/src/gl.cpp"} mutableCopy];
    if (!NSThread.isMainThread || !host.window) {
        report[@"status"] = @"invalid_host"; SaveProgress(report); return report;
    }
    if (!TFMPrepareSteamSDKBoundary()) {
        report[@"status"]=@"steam_sdk_boundary_preparation_failed";
        report[@"sdk_client_boundary"]=TFMSteamSDKBoundaryObservation();SaveProgress(report);return report;
    }
    SaveProgress(report);
    dlerror();
    // Retain loaded images for process lifetime: original global C++ objects and
    // ObjC class registrations must not be invalidated by dlclose during tests.
    void *game = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!game) {
        const char *error = dlerror();
        report[@"status"] = @"dlopen_failed";
        report[@"error"] = error ? @(error) : @"No loader detail";
        SaveProgress(report); return report;
    }
    report[@"status"] = @"dlopen_complete"; SaveProgress(report);
    const void *(*assemble)(void *, const void *(*)(void *, const char *)) = dlsym(game, "C_GrGLInterface_MakeAssembledInterface");
    void *(*makeGL)(const void *, const void *) = dlsym(game, "C_GrDirectContext_MakeGL");
    void (*unref)(const void *) = dlsym(game, "C_SkRefCntBase_unref");
    report[@"entrypoints"] = @{@"assemble": @(assemble != NULL), @"makeGL": @(makeGL != NULL), @"unref": @(unref != NULL)};
    if (!assemble || !makeGL || !unref) { report[@"status"] = @"entrypoint_missing"; SaveProgress(report); return report; }
    void *gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!gles) { report[@"status"] = @"gles_load_failed"; SaveProgress(report); return report; }
    EAGLContext *previous = EAGLContext.currentContext;
    TFMGLSurface *surface = [[TFMGLSurface alloc] initWithFrame:CGRectMake(0, 0, 96, 96)];
    [host addSubview:surface];
    NSError *error = nil;
    void *direct = NULL;
    void (*closeWrapper)(void) = NULL;
    TFMGL4ESFunctionResolver renderResolver = NULL;
    @try {
        if (![surface bindDrawable:&error]) {
            report[@"status"] = @"surface_failed"; report[@"error"] = error.localizedDescription ?: @"Unknown";
        } else {
            const GLubyte *version = glGetString(GL_VERSION);
            report[@"real_gl_version"] = version ? @((const char *)version) : @"unknown";
            NSMutableArray *lookups = [NSMutableArray array];
            LookupContext context = {gles, NULL, lookups};
            NSString *wrapperPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TFMGL4ES.dylib"];
            report[@"backend"] = @"native_gles";
            if ([[NSFileManager defaultManager] fileExistsAtPath:wrapperPath]) {
                report[@"backend"] = @"gl4es_desktop_2_1";
                NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
                freopen([[documents URLByAppendingPathComponent:@"gl4es-probe.log"] fileSystemRepresentation], "w", stdout);
                dup2(fileno(stdout), fileno(stderr)); setvbuf(stdout, NULL, _IONBF, 0);
                report[@"status"] = @"loading_gl4es"; SaveProgress(report);
                void *wrapper = dlopen(wrapperPath.UTF8String, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
                if (!wrapper) { report[@"status"] = @"gl4es_load_failed"; report[@"error"] = @(dlerror() ?: "unknown"); SaveProgress(report); return report; }
                void (*setProc)(void *(*)(const char *)) = dlsym(wrapper, "set_getprocaddress");
                void (*setSize)(void (*)(int *, int *)) = dlsym(wrapper, "set_getmainfbsize");
                void (*initialize)(void) = dlsym(wrapper, "initialize_gl4es");
                context.desktopResolver = dlsym(wrapper, "gl4es_GetProcAddress");
                closeWrapper = dlsym(wrapper, "close_gl4es");
                if (!setProc || !setSize || !initialize || !context.desktopResolver || !closeWrapper) {
                    closeWrapper = NULL; report[@"status"] = @"gl4es_entrypoint_missing"; SaveProgress(report); return report;
                }
                driverLibrary = gles; backingWidth = surface.drawableWidth; backingHeight = surface.drawableHeight;
                setProc(DriverProc); setSize(BackingSize);
                report[@"status"] = @"initializing_gl4es"; SaveProgress(report);
                initialize();
                renderResolver = context.desktopResolver;
                const GLubyte *(*getString)(GLenum) = context.desktopResolver("glGetString");
                report[@"wrapper_gl_version"] = getString && getString(GL_VERSION) ? @((const char *)getString(GL_VERSION)) : @"unknown";
                report[@"wrapper_glsl_version"] = getString && getString(GL_SHADING_LANGUAGE_VERSION) ? @((const char *)getString(GL_SHADING_LANGUAGE_VERSION)) : @"unknown";
            }
            report[@"status"] = @"assembling_original_skia_interface"; SaveProgress(report);
            const void *interface = assemble(&context, GetGLProc);
            report[@"gl_lookups"] = lookups;
            report[@"original_skia_interface_created"] = @(interface != NULL);
            if (interface) {
                report[@"status"] = @"creating_original_skia_context"; SaveProgress(report);
                // rust-skia 0.87.0 sp(interface) adopts the existing reference.
                // MakeGL therefore consumes that reference, including on failure.
                direct = makeGL(interface, NULL);
                report[@"original_skia_context_created"] = @(direct != NULL);
                report[@"status"] = direct ? @"original_skia_context_created" : @"original_skia_context_failed";
            } else report[@"status"] = @"original_skia_interface_failed";
        }
    } @finally {
        if (direct) unref(direct);
        if (renderResolver) {
            report[@"status"] = @"testing_gl4es_rendering"; SaveProgress(report);
            report[@"gl4es_render_probe"] = TFMGL4ESRenderProbe(renderResolver, surface);
            report[@"status"] = direct ? @"original_skia_context_created" : @"original_skia_context_failed";
        }
        if (closeWrapper) closeWrapper();
        [surface invalidate]; [surface removeFromSuperview];
        [EAGLContext setCurrentContext:previous];
    }
    SaveProgress(report);
    return report;
}

BOOL TFMGameStartupRequested(void) {
    NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
    if ([arguments containsObject:@"--tfm-run-main"] || TFMSteamCombinedLaunchRequested()) return YES;
    // Explicit diagnostic modes retain their isolation. A complete personal
    // game bundle launched normally from its icon opens the game directly.
    for (NSString *argument in arguments) if ([argument hasPrefix:@"--tfm-"]) return NO;
    NSString *bundle=NSBundle.mainBundle.bundlePath;
    NSFileManager *files=NSFileManager.defaultManager;
    return [files fileExistsAtPath:[bundle stringByAppendingPathComponent:@"bundle.game_data"]] &&
        [files fileExistsAtPath:[bundle stringByAppendingPathComponent:@"Frameworks/TeamfightManager2.dylib"]];
}

void TFMRunOriginalGameMainIfRequested(UIView *host) {
    if (!TFMGameStartupRequested()) return;
    NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *progress = [documents URLByAppendingPathComponent:@"game-main-progress.json"];
    NSMutableDictionary *state = [@{@"status": @"preparing", @"game_main_called": @NO,
        @"pid": @(getpid()), @"started_at_unix": @(NSDate.date.timeIntervalSince1970),
        @"actual_thread_stack_bytes": @(pthread_get_stacksize_np(pthread_self())),
        @"requested_main_stack_bytes": NSBundle.mainBundle.infoDictionary[@"TFMRequestedMainStackBytes"] ?: @0,
        @"scope": @"Original game startup experiment. Steam authentication and game success are not simulated."} mutableCopy];
    void (^save)(void) = ^{
        [[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:NULL] writeToURL:progress atomically:YES];
    };
    save();
    if (!NSThread.isMainThread || !host.window) { state[@"status"] = @"invalid_host"; save(); return; }
    if (setenv("SteamAppId","3009300",1) || setenv("SteamGameId","3009300",1)) {
        state[@"status"]=@"app_id_environment_failed";save();return;
    }
    state[@"app_id_selected_before_vendor_load"]=@3009300;
    if (!TFMPrepareSteamSDKBoundary()) {
        state[@"status"]=@"steam_sdk_boundary_preparation_failed";
        state[@"sdk_client_boundary"]=TFMSteamSDKBoundaryObservation();save();return;
    }
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TeamfightManager2.dylib"];
    void *game = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!game) { state[@"status"] = @"load_failed"; state[@"error"] = @(dlerror() ?: "unknown"); save(); return; }
    void (*setHost)(UIWindow *) = dlsym(game, "TFMAppKitSetHostWindow");
    int (*entry)(int, char **) = dlsym(game, "main");
    Dl_info resolved = {0};
    if (!setHost || !entry || !dladdr((const void *)entry, &resolved) || !resolved.dli_fname ||
        ![@(resolved.dli_fname).lastPathComponent isEqualToString:@"TeamfightManager2.dylib"]) {
        state[@"status"] = @"entry_or_host_bridge_missing"; save(); return;
    }
    setHost(host.window);
    NSString *filesystemPath=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TFMlibSystem.dylib"];
    if ([NSFileManager.defaultManager fileExistsAtPath:filesystemPath]) {
        void *filesystem=dlopen(filesystemPath.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        int (*prepareCwd)(const char *)=filesystem?dlsym(filesystem,"chdir"):NULL;
        if (!prepareCwd || prepareCwd(NSBundle.mainBundle.bundlePath.fileSystemRepresentation)!=0) {
            state[@"status"]=@"writable_game_runtime_preparation_failed";save();return;
        }
        state[@"writable_game_runtime_prepared"]=@YES;
        state[@"community_mod_setup"]=TFMPrepareCommunityMods(documents);
    } else if (chdir(documents.fileSystemRepresentation) != 0) { state[@"status"] = @"chdir_failed"; save(); return; }
    if (TFMSteamCombinedLaunchRequested() && !TFMInstallSteamGameCoordinator()) {
        state[@"status"]=@"steam_game_coordinator_configuration_failed";save();return;
    }
    freopen([[documents URLByAppendingPathComponent:@"game-main.log"] fileSystemRepresentation], "w", stdout);
    dup2(fileno(stdout), fileno(stderr));
    setvbuf(stdout, NULL, _IONBF, 0);
    static char *argv[2];
    argv[0] = strdup(NSBundle.mainBundle.executablePath.fileSystemRepresentation); argv[1] = NULL;
    state[@"status"] = @"entering_original_main"; state[@"game_main_called"] = @YES; save();
    int result = entry(1, argv);
    state[@"status"] = @"original_main_returned"; state[@"return_code"] = @(result); save();
    // Returning from the real executable entry ends this experiment. Continuing
    // UIKit dispatch after Rust has destroyed winit would invoke stale delegates.
    fflush(NULL); _exit(result);
}
