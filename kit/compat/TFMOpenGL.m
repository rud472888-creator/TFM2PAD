// Original bounded NSOpenGL bridge; no upstream implementation copied.
// ABI and fallback checked against rust-windowing/glutin v0.32.1:
// glutin/src/api/cgl/{appkit,config,context,surface}.rs (Apache-2.0).
#import "TFMOpenGL.h"
#include <pthread.h>
#include <execinfo.h>
#import <UIKit/UIKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <QuartzCore/CAEAGLLayer.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

enum { PFAAllRenderers=1,PFATripleBuffer=3,PFADoubleBuffer=5,PFAStereo=6,
    PFAColorSize=8,PFAAlphaSize=11,PFADepthSize=12,PFAStencilSize=13,
    PFAMinimumPolicy=51,PFAMaximumPolicy=52,PFASampleBuffers=55,PFASamples=56,
    PFAColorFloat=58,PFAMultisample=59,PFAAccelerated=73,PFAAllowOffline=96,
    PFAProfile=99,PFAVirtualScreenCount=128,ProfileLegacy=0x1000,
    ProfileCore32=0x3200,ProfileCore41=0x4100,SwapInterval=222,SurfaceOpacity=236 };
enum { CGLNoError=0,CGLBadContext=10004,CGLBadState=10007,CGLBadValue=10008,CGLBadEnumeration=10010 };

@protocol TFMOpenGLSurface <NSObject>
@property(nonatomic,readonly) EAGLContext *context;
@property(nonatomic,readonly) GLuint framebuffer,colorRenderbuffer;
@property(nonatomic,readonly) GLint drawableWidth,drawableHeight;
- (BOOL)bindDrawable:(NSError **)error;
@end
@class NSOpenGLContext;
static NSOpenGLContext *TFMOwnedContext;
static __weak NSOpenGLContext *TFMCurrentContext;
static UIView<TFMOpenGLSurface> *TFMSurface;
static EAGLContext *TFMNativeContext;
static void *TFMDriver,*TFMWrapper,*TFMAppKit;
static void *(*TFMResolver)(const char *);
static void (*TFMRawBindFramebuffer)(GLenum,GLuint);
static void (*TFMRawBindRenderbuffer)(GLenum,GLuint);
static void (*TFMWrapperGetInteger)(GLenum,GLint *);
static void (*TFMWrapperBindFramebuffer)(GLenum,GLuint);
static void (*TFMWrapperBindRenderbuffer)(GLenum,GLuint);
static void (*TFMWrapperFlush)(void);
static UIView *(*TFMNativeView)(id);
static UIWindow *(*TFMHostWindow)(void);
static BOOL TFMInitializationAttempted,TFMInitialized;
static NSMutableDictionary *TFMState;
static NSMutableArray *TFMProfileAttempts;
// Observe only genuine renderer/GL4ES calls. In particular no diagnostic path
// calls glGetError: that would consume context-global state owned by the caller.
static uint64_t TFMPresents,TFMNativeClears,TFMNativeDrawArrays,TFMNativeDrawElements,TFMNativeInstancedDraws;
static uint64_t TFMNativeShaderSources,TFMNativeCompiles,TFMNativeCompileFailures,TFMNativeLinks,TFMNativeLinkFailures;
static uint64_t TFMNativeErrorQueries,TFMNativeErrors,TFMAppErrorQueries,TFMAppErrors,TFMDefaultFBDriverBinds;
static GLenum TFMLastNativeError,TFMLastAppError;
static GLuint TFMLastDriverFBO,TFMLastDrawFBO,TFMLastDrawProgram;
static GLbitfield TFMLastClearMask;
static NSMutableArray *TFMShaderFailures,*TFMShaderVersions,*TFMResolvedProcedures;
static NSDictionary *TFMInitializationCounters;
static GLenum (*TFMWrapperGetError)(void);
static NSMutableArray *TFMNativeErrorSamples,*TFMAppErrorSamples;
static unsigned TFMNativeErrorPhaseSamples[3],TFMAppErrorPhaseSamples[3];
static uint64_t TFMPreviousSnapshotFrame,TFMPreviousSnapshotClears,TFMPreviousSnapshotArrays,TFMPreviousSnapshotElements,TFMPreviousSnapshotInstanced;
static uint64_t TFMPreviousSnapshotCompiles,TFMPreviousSnapshotLinks,TFMPreviousSnapshotNativeErrors,TFMPreviousSnapshotAppErrors;
static uint64_t TFMLastDrawAtPresentedCount,TFMLastClearAtPresentedCount;
static uint64_t TFMNativeRenderbufferAllocations,TFMAppRenderbufferAllocations,TFMAlphaRenderbufferTranslations;
static NSDictionary *TFMLastNativeRenderbufferAllocation,*TFMLastAppRenderbufferAllocation;
static void (*TFMWrapperRenderbufferStorage)(GLenum,GLenum,GLsizei,GLsizei);
static void (*TFMWrapperRenderbufferStorageMultisample)(GLenum,GLsizei,GLenum,GLsizei,GLsizei);
static void (*TFMWrapperDeleteFramebuffers)(GLsizei,const GLuint *);
static uint64_t TFMDeletedBoundFramebufferRebindings,TFMMaxSamplesQueries;

static void TFMGLRecord(NSString *stage,NSDictionary *details) {
    if (!TFMState) TFMState=[NSMutableDictionary dictionary];
    [TFMState addEntriesFromDictionary:details ?: @{}];
    TFMState[@"stage"]=stage;TFMState[@"pid"]=@(getpid());
    TFMState[@"timestamp_unix"]=@(NSDate.date.timeIntervalSince1970);
    TFMState[@"profile_attempts"]=TFMProfileAttempts.copy ?: @[];
    NSURL *directory=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *data=[NSJSONSerialization dataWithJSONObject:TFMState options:NSJSONWritingPrettyPrinted error:NULL];
    if (!data || ![data writeToURL:[directory URLByAppendingPathComponent:@"opengl-progress.json"] options:NSDataWritingAtomic error:NULL])
        fprintf(stderr,"TFM_OPENGL_DIAGNOSTIC_WRITE_FAILED\n");
    fprintf(stderr,"TFM_OPENGL stage=%s\n",stage.UTF8String);fflush(stderr);
}
__attribute__((noreturn)) static void TFMGLStop(id object,SEL selector,NSString *reason) {
    TFMGLRecord(@"unsupported",@{@"class":@(object?object_getClassName(object):"(nil)"),
        @"selector":@(selector?sel_getName(selector):"(null)"),@"reason":reason ?: @"unsupported",@"exit_code":@78});
    fflush(stderr);_exit(78);
}
static void TFMGLMain(void) { if (!NSThread.isMainThread) TFMGLStop(nil,NULL,@"main-thread-only bridge"); }
static NSArray *TFMBoundedCallStack(void) {
    void *addresses[24];int count=backtrace(addresses,24);NSMutableArray *trace=[NSMutableArray array];
    for (int i=0;i<count;i++) {
        Dl_info info={0};dladdr(addresses[i],&info);
        [trace addObject:@{@"image":info.dli_fname?@(info.dli_fname).lastPathComponent:@"unknown",
            @"offset":@((uintptr_t)addresses[i]-(uintptr_t)info.dli_fbase),@"symbol":info.dli_sname?@(info.dli_sname):@"stripped"}];
    }return trace;
}
static void TFMSampleReturnedError(GLenum result,BOOL native) {
    // Query-site stacks do not identify the command that generated an error.
    // Capture only the first two nonzero results in initialization, early game,
    // and >=300-present phases, leaving later intro/blank errors observable.
    NSUInteger phase=!TFMInitialized?0:(TFMPresents<300?1:2);
    unsigned *counts=native?TFMNativeErrorPhaseSamples:TFMAppErrorPhaseSamples;
    if (counts[phase]>=2) return;counts[phase]++;
    NSMutableArray *__strong *samples=native?&TFMNativeErrorSamples:&TFMAppErrorSamples;
    if (!*samples) *samples=[NSMutableArray array];
    [*samples addObject:@{@"returned_error":@(result),@"presented_frames_before_query":@(TFMPresents),
        @"phase":phase==0?@"wrapper-initialization":(phase==1?@"early-game":@"after-300-presents"),
        @"query_call_stack":TFMBoundedCallStack(),
        @"most_recent_native_renderbuffer_allocation":TFMLastNativeRenderbufferAllocation ?: @{},
        @"most_recent_app_renderbuffer_allocation":TFMLastAppRenderbufferAllocation ?: @{},
        @"scope":@"existing caller query returned this unchanged value; stack is query site, allocation records are temporal context, not proof of causation"}];
    TFMGLRecord(@"renderer-error-query-observed",@{native?@"native_error_query_samples":@"app_error_query_samples":[*samples copy]});
}

static void TFMObserveDraw(void) {
    TFMLastDrawAtPresentedCount=TFMPresents;
    // Bounded native-state queries; counters themselves remain cumulative.
    uint64_t draws=TFMNativeDrawArrays+TFMNativeDrawElements+TFMNativeInstancedDraws;
    if (draws<=16 || (TFMPresents<3 || TFMPresents%120==119)) {
        GLint framebuffer=0,program=0;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&framebuffer);glGetIntegerv(GL_CURRENT_PROGRAM,&program);
        TFMLastDrawFBO=(GLuint)framebuffer;TFMLastDrawProgram=(GLuint)program;
    }
}
static void TFMDriverClear(GLbitfield mask) { TFMNativeClears++;TFMLastClearMask=mask;TFMLastClearAtPresentedCount=TFMPresents;glClear(mask); }
static void TFMDriverDrawArrays(GLenum mode,GLint first,GLsizei count) {
    TFMNativeDrawArrays++;TFMObserveDraw();glDrawArrays(mode,first,count);
}
static void TFMDriverDrawElements(GLenum mode,GLsizei count,GLenum type,const void *indices) {
    TFMNativeDrawElements++;TFMObserveDraw();glDrawElements(mode,count,type,indices);
}
static void TFMDriverDrawArraysInstanced(GLenum mode,GLint first,GLsizei count,GLsizei instances) {
    TFMNativeInstancedDraws++;TFMObserveDraw();glDrawArraysInstanced(mode,first,count,instances);
}
static void TFMDriverDrawElementsInstanced(GLenum mode,GLsizei count,GLenum type,const void *indices,GLsizei instances) {
    TFMNativeInstancedDraws++;TFMObserveDraw();glDrawElementsInstanced(mode,count,type,indices,instances);
}
static void TFMDriverShaderSource(GLuint shader,GLsizei count,const GLchar *const *strings,const GLint *lengths) {
    TFMNativeShaderSources++;
    if (!TFMShaderVersions) TFMShaderVersions=[NSMutableArray array];
    // Retain only a bounded #version declaration, never complete game shaders.
    if (TFMShaderVersions.count<8 && count>0 && strings && strings[0]) {
        size_t size=(lengths && lengths[0]>=0)?(size_t)lengths[0]:strlen(strings[0]);
        size=MIN(size,(size_t)96);size_t end=0;while(end<size && strings[0][end]!='\n') end++;
        if (end>=8 && !strncmp(strings[0],"#version",8)) {
            NSString *line=[[NSString alloc] initWithBytes:strings[0] length:end encoding:NSUTF8StringEncoding];
            if (line && ![TFMShaderVersions containsObject:line]) [TFMShaderVersions addObject:line];
        }
    }
    glShaderSource(shader,count,strings,lengths);
}
static void TFMShaderFailure(GLuint object,BOOL program) {
    if (!TFMShaderFailures) TFMShaderFailures=[NSMutableArray array];
    if (TFMShaderFailures.count>=8) return;
    GLchar log[4097]={0};GLsizei written=0;
    if (program) glGetProgramInfoLog(object,4096,&written,log);else glGetShaderInfoLog(object,4096,&written,log);
    NSUInteger size=(NSUInteger)MAX(0,MIN(written,4096));
    NSString *message=[[NSString alloc] initWithBytes:log length:size encoding:NSUTF8StringEncoding] ?: @"non-UTF8 shader log";
    [TFMShaderFailures addObject:@{@"kind":program?@"native-program-link":@"native-shader-compile",@"object":@(object),@"log":message,@"log_capacity_bytes":@4096,
        @"wrapper_initialized":@(TFMInitialized),@"presented_frames_before_failure":@(TFMPresents)}];
    TFMGLRecord(@"native-shader-failure-observed",@{@"shader_failures":TFMShaderFailures.copy});
}
static void TFMDriverCompileShader(GLuint shader) {
    TFMNativeCompiles++;glCompileShader(shader);GLint success=0;glGetShaderiv(shader,GL_COMPILE_STATUS,&success);
    if (!success) { TFMNativeCompileFailures++;TFMShaderFailure(shader,NO); }
}
static void TFMDriverLinkProgram(GLuint program) {
    TFMNativeLinks++;glLinkProgram(program);GLint success=0;glGetProgramiv(program,GL_LINK_STATUS,&success);
    if (!success) { TFMNativeLinkFailures++;TFMShaderFailure(program,YES); }
}
static void TFMDriverRenderbufferStorage(GLenum target,GLenum format,GLsizei width,GLsizei height) {
    GLint bound=0;glGetIntegerv(GL_RENDERBUFFER_BINDING,&bound);
    // Desktop GL_ALPHA8 (0x803c) is not an ES3 renderbuffer storage format.
    // main016's actual Skia request repeatedly failed for its 128x64 A8 atlas.
    // RGBA8 is a renderable superset with the same eight-bit alpha channel;
    // using R8 would put coverage in red and break the existing alpha shader.
    // Keep this below GL4ES so its logical format/attachment bookkeeping remains
    // ALPHA8. Its existing color blit copies RGBA, retaining the alpha channel.
    GLenum nativeFormat=(target==GL_RENDERBUFFER && format==0x803c)?GL_RGBA8:format;
    if (nativeFormat!=format) TFMAlphaRenderbufferTranslations++;
    glRenderbufferStorage(target,nativeFormat,width,height);
    // ES3 metadata queries are valid for a bound object even when storage failed.
    // The caller's next existing glGetError retains the original driver result.
    GLint actualWidth=0,actualHeight=0,actualFormat=0,actualSamples=0;
    if (bound && target==GL_RENDERBUFFER) {
        glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_WIDTH,&actualWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_HEIGHT,&actualHeight);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_INTERNAL_FORMAT,&actualFormat);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_SAMPLES,&actualSamples);
    }
    TFMLastNativeRenderbufferAllocation=@{@"sequence":@(++TFMNativeRenderbufferAllocations),
        @"procedure":@"glRenderbufferStorage",@"target":@(target),@"internal_format":@(format),
        @"native_internal_format_submitted":@(nativeFormat),
        @"format_translation":nativeFormat!=format?@"desktop ALPHA8 backed by native RGBA8; alpha channel preserved":@"none",
        @"width":@(width),@"height":@(height),@"bound_native_renderbuffer":@(bound),
        @"actual_width_after_call":@(actualWidth),@"actual_height_after_call":@(actualHeight),
        @"actual_internal_format_after_call":@(actualFormat),@"actual_samples_after_call":@(actualSamples),
        @"presented_frames_before_command":@(TFMPresents),@"native_error_query_count_before_command":@(TFMNativeErrorQueries),
        @"scope":@"genuine driver command plus ES3 object metadata; no error query performed"};
}
static void TFMApplicationRenderbufferStorage(GLenum target,GLenum format,GLsizei width,GLsizei height) {
    TFMLastAppRenderbufferAllocation=@{@"sequence":@(++TFMAppRenderbufferAllocations),@"procedure":@"glRenderbufferStorage",
        @"target":@(target),@"internal_format":@(format),@"width":@(width),@"height":@(height),
        @"presented_frames_before_command":@(TFMPresents),@"app_error_query_count_before_command":@(TFMAppErrorQueries)};
    TFMWrapperRenderbufferStorage(target,format,width,height);
}
static void TFMApplicationRenderbufferStorageMultisample(GLenum target,GLsizei samples,GLenum format,GLsizei width,GLsizei height) {
    TFMLastAppRenderbufferAllocation=@{@"sequence":@(++TFMAppRenderbufferAllocations),@"procedure":@"glRenderbufferStorageMultisample",
        @"target":@(target),@"samples":@(samples),@"internal_format":@(format),@"width":@(width),@"height":@(height),
        @"presented_frames_before_command":@(TFMPresents),@"app_error_query_count_before_command":@(TFMAppErrorQueries)};
    TFMWrapperRenderbufferStorageMultisample(target,samples,format,width,height);
}
static void TFMApplicationGetInteger(GLenum name,GLint *values) {
    // Native ES3's MAX_SAMPLES is not the wrapper's capability: GL4ES 1.1.7
    // silently implements multisample storage as single-sample storage. Report
    // zero supported MSAA samples so Skia can select a genuine single-sample
    // path instead of constructing a render target that only claims MSAA.
    if (name==GL_MAX_SAMPLES && values) { TFMMaxSamplesQueries++;*values=0;return; }
    TFMWrapperGetInteger(name,values);
}
static void TFMApplicationDeleteFramebuffers(GLsizei count,const GLuint *framebuffers) {
    if (count>0 && framebuffers) {
        GLint draw=0,read=0;
        TFMWrapperGetInteger(GL_DRAW_FRAMEBUFFER_BINDING,&draw);
        TFMWrapperGetInteger(GL_READ_FRAMEBUFFER_BINDING,&read);
        BOOL deletingDraw=NO,deletingRead=NO;
        for (GLsizei i=0;i<count;i++) {
            if (framebuffers[i] && framebuffers[i]==(GLuint)draw) deletingDraw=YES;
            if (framebuffers[i] && framebuffers[i]==(GLuint)read) deletingRead=YES;
        }
        // Deleting a bound FBO unbinds it to the default framebuffer. Upstream
        // GL4ES instead leaves null logical pointers, crashing the next binding
        // query (main017 PC gl4es_commonGet+4560). Unbind before deletion through
        // the wrapper so its real default object and native mapping stay valid.
        if (deletingDraw && deletingRead) TFMWrapperBindFramebuffer(GL_FRAMEBUFFER,0);
        else if (deletingDraw) TFMWrapperBindFramebuffer(GL_DRAW_FRAMEBUFFER,0);
        else if (deletingRead) TFMWrapperBindFramebuffer(GL_READ_FRAMEBUFFER,0);
        if (deletingDraw || deletingRead) TFMDeletedBoundFramebufferRebindings++;
    }
    TFMWrapperDeleteFramebuffers(count,framebuffers);
}
static GLenum TFMDriverGetError(void) {
    GLenum result=glGetError();TFMNativeErrorQueries++;
    if (result!=GL_NO_ERROR) { TFMNativeErrors++;TFMLastNativeError=result;TFMSampleReturnedError(result,YES); }return result;
}
static GLenum TFMApplicationGetError(void) {
    GLenum result=TFMWrapperGetError();TFMAppErrorQueries++;
    if (result!=GL_NO_ERROR) { TFMAppErrors++;TFMLastAppError=result;TFMSampleReturnedError(result,NO); }return result;
}

static BOOL TFMFindHost(void) {
    if (TFMHostWindow && TFMNativeView) return YES;
    NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TFMAppKit.dylib"];
    TFMAppKit=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    if (!TFMAppKit) return NO;
    TFMHostWindow=dlsym(TFMAppKit,"TFMAppKitGetHostWindow");
    TFMNativeView=dlsym(TFMAppKit,"TFMAppKitGetNativeView");
    return TFMHostWindow && TFMNativeView && TFMHostWindow();
}
// GL4ES's logical default framebuffer is 0. EAGL's layer drawable has a real
// nonzero FBO. Only driver binds of 0 are remapped; wrapper object IDs stay intact.
static void TFMDriverBindFramebuffer(GLenum target,GLuint framebuffer) {
    GLuint actual=framebuffer ?: TFMSurface.framebuffer;
    if (!framebuffer) TFMDefaultFBDriverBinds++;TFMLastDriverFBO=actual;
    TFMRawBindFramebuffer(target,actual);
}
static void *TFMDriverProc(const char *name) {
    if (!name) return NULL;
    if (!strcmp(name,"glBindFramebuffer") || !strcmp(name,"glBindFramebufferOES") || !strcmp(name,"glBindFramebufferEXT")) return TFMDriverBindFramebuffer;
    // Renderbuffer 0 means unbound; unlike the default framebuffer, it must not
    // alias the drawable's color buffer. Presentation binds that buffer explicitly.
    void *native=dlsym(TFMDriver,name);if (!native) return NULL;
    if (!strcmp(name,"glClear")) return TFMDriverClear;
    if (!strcmp(name,"glDrawArrays")) return TFMDriverDrawArrays;
    if (!strcmp(name,"glDrawElements")) return TFMDriverDrawElements;
    if (!strcmp(name,"glDrawArraysInstanced")) return TFMDriverDrawArraysInstanced;
    if (!strcmp(name,"glDrawElementsInstanced")) return TFMDriverDrawElementsInstanced;
    if (!strcmp(name,"glShaderSource")) return TFMDriverShaderSource;
    if (!strcmp(name,"glCompileShader")) return TFMDriverCompileShader;
    if (!strcmp(name,"glLinkProgram")) return TFMDriverLinkProgram;
    if (!strcmp(name,"glRenderbufferStorage") || !strcmp(name,"glRenderbufferStorageOES")) return TFMDriverRenderbufferStorage;
    if (!strcmp(name,"glGetError")) return TFMDriverGetError;
    return native;
}
static void TFMBackingSize(int *width,int *height) {
    if (width) *width=TFMSurface.drawableWidth;if (height) *height=TFMSurface.drawableHeight;
}

static BOOL TFMInitializeWrapper(void) {
    if (TFMInitialized) return YES;
    if (TFMInitializationAttempted) return NO;
    TFMInitializationAttempted=YES;
    TFMDriver=dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    TFMRawBindFramebuffer=TFMDriver?dlsym(TFMDriver,"glBindFramebuffer"):NULL;
    TFMRawBindRenderbuffer=TFMDriver?dlsym(TFMDriver,"glBindRenderbuffer"):NULL;
    if (!TFMRawBindFramebuffer || !TFMRawBindRenderbuffer) return NO;
    NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TFMGL4ES.dylib"];
    // The wrapper's supported desktop contract is 2.1, never a fabricated 4.1.
    setenv("LIBGL_GL","21",1);setenv("LIBGL_ES","2",1);
    TFMWrapper=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    void (*setProc)(void *(*)(const char *))=TFMWrapper?dlsym(TFMWrapper,"set_getprocaddress"):NULL;
    void (*setSize)(void (*)(int *,int *))=TFMWrapper?dlsym(TFMWrapper,"set_getmainfbsize"):NULL;
    void (*initialize)(void)=TFMWrapper?dlsym(TFMWrapper,"initialize_gl4es"):NULL;
    TFMResolver=TFMWrapper?dlsym(TFMWrapper,"gl4es_GetProcAddress"):NULL;
    if (!setProc || !setSize || !initialize || !TFMResolver) return NO;
    setProc(TFMDriverProc);setSize(TFMBackingSize);initialize();
    const GLubyte *(*getString)(GLenum)=TFMResolver("glGetString");
    const char *version=getString?(const char *)getString(GL_VERSION):NULL;
    if (!version || strncmp(version,"2.1",3)) {
        TFMGLRecord(@"wrapper-version-rejected",@{@"observed_version":version?@(version):@"missing"});return NO;
    }
    TFMWrapperGetInteger=TFMResolver("glGetIntegerv");
    TFMWrapperBindFramebuffer=TFMResolver("glBindFramebuffer");
    TFMWrapperBindRenderbuffer=TFMResolver("glBindRenderbuffer");
    TFMWrapperFlush=TFMResolver("glFlush");
    TFMWrapperGetError=TFMResolver("glGetError");
    TFMWrapperRenderbufferStorage=TFMResolver("glRenderbufferStorage");
    TFMWrapperRenderbufferStorageMultisample=TFMResolver("glRenderbufferStorageMultisample");
    TFMWrapperDeleteFramebuffers=TFMResolver("glDeleteFramebuffers");
    if (!TFMWrapperGetInteger || !TFMWrapperBindFramebuffer || !TFMWrapperBindRenderbuffer || !TFMWrapperFlush) return NO;
    TFMInitialized=YES;
    TFMWrapperBindFramebuffer(GL_FRAMEBUFFER,0);TFMWrapperBindRenderbuffer(GL_RENDERBUFFER,0);
    TFMInitializationCounters=@{@"clear_calls":@(TFMNativeClears),@"draw_arrays_calls":@(TFMNativeDrawArrays),
        @"draw_elements_calls":@(TFMNativeDrawElements),@"instanced_draw_calls":@(TFMNativeInstancedDraws),
        @"shader_compiles":@(TFMNativeCompiles),@"program_links":@(TFMNativeLinks)};
    TFMGLRecord(@"wrapper-initialized",@{@"wrapper_gl_version":@(version),
        @"wrapper_glsl_version":getString(GL_SHADING_LANGUAGE_VERSION)?@((const char *)getString(GL_SHADING_LANGUAGE_VERSION)):@"missing",
        @"native_gl_version":glGetString(GL_VERSION)?@((const char *)glGetString(GL_VERSION)):@"missing",
        @"default_framebuffer_mapping":@"wrapper 0 maps to actual EAGL drawable FBO",
        @"context_limit":@"one retained native/wrapper context per process; sharing rejected"});
    return YES;
}

@interface TFMOpenGLObject : NSObject @end
@implementation TFMOpenGLObject
- (void)doesNotRecognizeSelector:(SEL)selector { TFMGLStop(self,selector,@"unsupported NSOpenGL selector"); }
+ (void)doesNotRecognizeSelector:(SEL)selector { TFMGLStop(self,selector,@"unsupported NSOpenGL class selector"); }
@end
@interface NSOpenGLPixelFormat : TFMOpenGLObject
@property(nonatomic,strong) NSDictionary<NSNumber *,NSNumber *> *tfmAttributes;
@end
@implementation NSOpenGLPixelFormat
- (instancetype)initWithAttributes:(const uint32_t *)attributes {
    TFMGLMain();if (!attributes) return nil;
    NSMutableDictionary *values=[NSMutableDictionary dictionary];BOOL terminated=NO,known=YES;
    for (NSUInteger i=0;i<96;i++) {
        uint32_t key=attributes[i];if (!key) { terminated=YES;break; }
        switch (key) {
            case PFAColorSize:case PFAAlphaSize:case PFADepthSize:case PFAStencilSize:
            case PFASampleBuffers:case PFASamples:case PFAProfile:
                if (++i>=96) { known=NO;break; }values[@(key)]=@(attributes[i]);break;
            case PFAAllRenderers:case PFAMinimumPolicy:case PFAMaximumPolicy:case PFAAllowOffline:
            case PFADoubleBuffer:case PFAAccelerated:case PFATripleBuffer:case PFAStereo:case PFAColorFloat:case PFAMultisample:
                values[@(key)]=@1;break;
            default:known=NO;break;
        }
        if (!known) break;
    }
    uint32_t profile=[values[@(PFAProfile)] unsignedIntValue] ?: ProfileLegacy;
    NSString *reason=nil;
    if (!terminated || !known) reason=@"unterminated or unsupported attribute";
    else if (profile!=ProfileLegacy) reason=@"core 3.2/4.1 unavailable; GL4ES negotiates desktop 2.1 legacy";
    else if ([values[@(PFATripleBuffer)] boolValue] || [values[@(PFAStereo)] boolValue] || [values[@(PFAColorFloat)] boolValue]) reason=@"triple buffering, stereo and float-color drawable unavailable";
    else if ([values[@(PFASampleBuffers)] intValue]>0 || [values[@(PFASamples)] intValue]>1) reason=@"multisampled native drawable unavailable";
    else if ([values[@(PFAColorSize)] intValue]>32 || [values[@(PFAAlphaSize)] intValue]>8 || [values[@(PFADepthSize)] intValue]>24 || [values[@(PFAStencilSize)] intValue]>8) reason=@"requested storage exceeds RGBA8/depth24/stencil8 drawable";
    if (!TFMProfileAttempts) TFMProfileAttempts=[NSMutableArray array];
    [TFMProfileAttempts addObject:@{@"requested_profile":@(profile),@"accepted":@(reason==nil),@"reason":reason ?: @"legacy candidate; native context/storage not created yet",@"attributes":values.description}];
    TFMGLRecord(reason?@"pixel-format-rejected":@"legacy-pixel-format-selected",@{@"negotiated_desktop_api":@"GL4ES OpenGL 2.1 legacy",@"core_4_1_supported":@NO});
    if (reason) return nil;
    if ((self=[super init])) self.tfmAttributes=@{@(PFAProfile):@(ProfileLegacy),@(PFAColorSize):@32,@(PFAAlphaSize):@8,
        @(PFADepthSize):@24,@(PFAStencilSize):@8,@(PFASampleBuffers):@0,@(PFASamples):@0,
        @(PFADoubleBuffer):@([values[@(PFADoubleBuffer)] boolValue]),@(PFAAccelerated):@1,
        @(PFATripleBuffer):@0,@(PFAStereo):@0,@(PFAColorFloat):@0,@(PFAVirtualScreenCount):@1};
    return self;
}
- (void)getValues:(int *)values forAttribute:(uint32_t)attribute forVirtualScreen:(int)screen {
    TFMGLMain();NSNumber *value=self.tfmAttributes[@(attribute)];
    if (!values || screen!=0 || !value) TFMGLStop(self,_cmd,@"unsupported pixel-format query");
    *values=value.intValue;
}
- (int)numberOfVirtualScreens { return 1; }
@end

@interface NSOpenGLContext : TFMOpenGLObject
@property(nonatomic,strong) NSOpenGLPixelFormat *pixelFormat;
@property(nonatomic,strong) id view;
@property(nonatomic) int tfmSwapInterval;
@property(nonatomic) BOOL tfmOpaque;
- (void)update;
- (void)makeCurrentContext;
@end
static BOOL TFMBindSurface(BOOL preserveWrapperState) {
    GLint framebuffer=0,renderbuffer=0;
    if (preserveWrapperState && TFMInitialized) {
        TFMWrapperGetInteger(GL_FRAMEBUFFER_BINDING,&framebuffer);TFMWrapperGetInteger(GL_RENDERBUFFER_BINDING,&renderbuffer);
    }
    NSError *error=nil;
    if (![TFMSurface bindDrawable:&error]) {
        TFMGLRecord(@"drawable-bind-failed",@{@"drawable_error":error.localizedDescription ?: @"unknown", @"drawable_error_code":@(error.code),
            @"surface_has_window":@(TFMSurface.window!=nil), @"surface_bounds":NSStringFromCGRect(TFMSurface.bounds)});
        fprintf(stderr,"TFM_OPENGL drawable-error=%s code=%ld\n",(error.localizedDescription ?: @"unknown").UTF8String,(long)error.code);
        return NO;
    }
    if (preserveWrapperState && TFMInitialized) {
        TFMWrapperBindFramebuffer(GL_FRAMEBUFFER,(GLuint)framebuffer);TFMWrapperBindRenderbuffer(GL_RENDERBUFFER,(GLuint)renderbuffer);
    }
    return YES;
}
static NSArray *TFMIntegerVector(GLenum name,NSUInteger count) {
    GLint values[4]={0};glGetIntegerv(name,values);NSMutableArray *result=[NSMutableArray array];
    for (NSUInteger i=0;i<MIN(count,(NSUInteger)4);i++) [result addObject:@(values[i])];return result;
}
static NSDictionary *TFMNativePixelSamples(void) {
    GLint readFBO=0,packBuffer=0,alignment=0,rowLength=0,skipRows=0,skipPixels=0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&readFBO);
    glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING,&packBuffer);glGetIntegerv(GL_PACK_ALIGNMENT,&alignment);
    glGetIntegerv(GL_PACK_ROW_LENGTH,&rowLength);glGetIntegerv(GL_PACK_SKIP_ROWS,&skipRows);glGetIntegerv(GL_PACK_SKIP_PIXELS,&skipPixels);
    // Bypass the wrapper only temporarily. ES3 read-FBO/pack state is restored
    // exactly; draw-FBO, viewport, scissor and renderer error flags are untouched.
    TFMRawBindFramebuffer(GL_READ_FRAMEBUFFER,TFMSurface.framebuffer);
    GLint hostReadBuffer=0;glGetIntegerv(GL_READ_BUFFER,&hostReadBuffer);glReadBuffer(GL_COLOR_ATTACHMENT0);
    GLenum status=glCheckFramebufferStatus(GL_READ_FRAMEBUFFER);
    NSMutableArray *samples=[NSMutableArray array];
    if (status==GL_FRAMEBUFFER_COMPLETE && TFMSurface.drawableWidth>0 && TFMSurface.drawableHeight>0) {
        glBindBuffer(GL_PIXEL_PACK_BUFFER,0);glPixelStorei(GL_PACK_ALIGNMENT,1);
        glPixelStorei(GL_PACK_ROW_LENGTH,0);glPixelStorei(GL_PACK_SKIP_ROWS,0);glPixelStorei(GL_PACK_SKIP_PIXELS,0);
        for (int y=0;y<3;y++) for (int x=0;x<3;x++) {
            GLint px=(TFMSurface.drawableWidth*(2*x+1))/6,py=(TFMSurface.drawableHeight*(2*y+1))/6;
            GLubyte rgba[4]={0};glReadPixels(px,py,1,1,GL_RGBA,GL_UNSIGNED_BYTE,rgba);
            [samples addObject:@{@"pixel_x":@(px),@"pixel_y_from_bottom":@(py),@"rgba8":@[@(rgba[0]),@(rgba[1]),@(rgba[2]),@(rgba[3])]}];
        }
        glPixelStorei(GL_PACK_ALIGNMENT,alignment);glPixelStorei(GL_PACK_ROW_LENGTH,rowLength);
        glPixelStorei(GL_PACK_SKIP_ROWS,skipRows);glPixelStorei(GL_PACK_SKIP_PIXELS,skipPixels);glBindBuffer(GL_PIXEL_PACK_BUFFER,(GLuint)packBuffer);
    }
    glReadBuffer((GLenum)hostReadBuffer);TFMRawBindFramebuffer(GL_READ_FRAMEBUFFER,(GLuint)readFBO);
    return @{@"frame":@(TFMPresents+1),@"framebuffer_status":@(status),@"samples":samples,
        @"scope":@"nine native host RGBA8 pixels before EAGL presentation; not a full-frame or menu validation; no glGetError consumed"};
}
static NSDictionary *TFMFrameInterval(void) {
    uint64_t frame=TFMPresents+1;
    NSDictionary *result=@{@"from_present_exclusive":@(TFMPreviousSnapshotFrame),@"through_present_inclusive":@(frame),
        @"presents":@(frame-TFMPreviousSnapshotFrame),@"native_clears":@(TFMNativeClears-TFMPreviousSnapshotClears),
        @"native_draw_arrays":@(TFMNativeDrawArrays-TFMPreviousSnapshotArrays),@"native_draw_elements":@(TFMNativeDrawElements-TFMPreviousSnapshotElements),
        @"native_instanced_draws":@(TFMNativeInstancedDraws-TFMPreviousSnapshotInstanced),@"native_shader_compiles":@(TFMNativeCompiles-TFMPreviousSnapshotCompiles),
        @"native_program_links":@(TFMNativeLinks-TFMPreviousSnapshotLinks),@"native_nonzero_errors_returned":@(TFMNativeErrors-TFMPreviousSnapshotNativeErrors),
        @"app_nonzero_errors_returned":@(TFMAppErrors-TFMPreviousSnapshotAppErrors),
        @"presents_since_last_native_draw":@(TFMPresents-TFMLastDrawAtPresentedCount),@"presents_since_last_native_clear":@(TFMPresents-TFMLastClearAtPresentedCount)};
    TFMPreviousSnapshotFrame=frame;TFMPreviousSnapshotClears=TFMNativeClears;
    TFMPreviousSnapshotArrays=TFMNativeDrawArrays;TFMPreviousSnapshotElements=TFMNativeDrawElements;TFMPreviousSnapshotInstanced=TFMNativeInstancedDraws;
    TFMPreviousSnapshotCompiles=TFMNativeCompiles;TFMPreviousSnapshotLinks=TFMNativeLinks;
    TFMPreviousSnapshotNativeErrors=TFMNativeErrors;TFMPreviousSnapshotAppErrors=TFMAppErrors;return result;
}
static NSDictionary *TFMNativeInputHierarchy(void) {
    UIWindow *window=TFMHostWindow?TFMHostWindow():nil;
    CGPoint point=CGPointMake(CGRectGetMidX(window.bounds),CGRectGetMidY(window.bounds));
    UIView *hit=[window hitTest:point withEvent:nil];NSMutableArray *chain=[NSMutableArray array];
    for (UIView *view=hit;view && chain.count<8;view=view.superview)
        [chain addObject:@{@"class":NSStringFromClass(view.class),@"user_interaction_enabled":@(view.userInteractionEnabled),@"hidden":@(view.hidden),@"alpha":@(view.alpha)}];
    return @{@"surface_class":TFMSurface?NSStringFromClass(TFMSurface.class):@"none",@"surface_user_interaction_enabled":@(TFMSurface.userInteractionEnabled),
        @"surface_superview_class":TFMSurface.superview?NSStringFromClass(TFMSurface.superview.class):@"none",@"surface_has_window":@(TFMSurface.window!=nil),
        @"window_center_hit_test_ancestor_chain":chain,@"scope":@"native UIKit hit-test observation only; does not prove physical touch injection or winit dispatch"};
}
static NSDictionary *TFMGraphicsSnapshot(GLint wrapperFBO) {
    GLint nativeDraw=0,nativeRead=0,program=0,renderbuffer=0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&nativeDraw);glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&nativeRead);
    glGetIntegerv(GL_CURRENT_PROGRAM,&program);glGetIntegerv(GL_RENDERBUFFER_BINDING,&renderbuffer);
    GLfloat clear[4]={0};GLboolean mask[4]={0};
    glGetFloatv(GL_COLOR_CLEAR_VALUE,clear);glGetBooleanv(GL_COLOR_WRITEMASK,mask);
    return @{@"native_clear_calls":@(TFMNativeClears),@"native_draw_arrays_calls":@(TFMNativeDrawArrays),
        @"native_draw_elements_calls":@(TFMNativeDrawElements),@"native_instanced_draw_calls":@(TFMNativeInstancedDraws),
        @"native_shader_sources":@(TFMNativeShaderSources),@"native_shader_compiles":@(TFMNativeCompiles),
        @"native_shader_compile_failures":@(TFMNativeCompileFailures),@"native_program_links":@(TFMNativeLinks),@"native_program_link_failures":@(TFMNativeLinkFailures),
        @"shader_failures":TFMShaderFailures.copy ?: @[],@"native_shader_version_lines":TFMShaderVersions.copy ?: @[],
        @"native_error_queries_by_wrapper":@(TFMNativeErrorQueries),@"native_nonzero_errors_returned_to_wrapper":@(TFMNativeErrors),@"last_native_error_returned":@(TFMLastNativeError),
        @"app_error_queries":@(TFMAppErrorQueries),@"app_nonzero_errors_returned":@(TFMAppErrors),@"last_app_error_returned":@(TFMLastAppError),
        @"native_error_query_samples":TFMNativeErrorSamples.copy ?: @[],@"app_error_query_samples":TFMAppErrorSamples.copy ?: @[],
        @"native_renderbuffer_allocations":@(TFMNativeRenderbufferAllocations),@"app_renderbuffer_allocations":@(TFMAppRenderbufferAllocations),
        @"alpha8_renderbuffer_native_rgba8_translations":@(TFMAlphaRenderbufferTranslations),
        @"bound_framebuffer_deletions_unbound_to_default":@(TFMDeletedBoundFramebufferRebindings),
        @"app_max_samples_queries":@(TFMMaxSamplesQueries),@"app_max_samples_capability":@0,
        @"multisample_storage_contract":@"app MAX_SAMPLES is 0 because GL4ES 1.1.7 implements single-sample storage only; native samples remain 0; explicit multisample calls retain upstream fallback and are not quality-equivalent",
        @"most_recent_native_renderbuffer_allocation":TFMLastNativeRenderbufferAllocation ?: @{},
        @"most_recent_app_renderbuffer_allocation":TFMLastAppRenderbufferAllocation ?: @{},
        @"interval_observation":TFMFrameInterval(),@"native_input_hierarchy":TFMNativeInputHierarchy(),
        @"wrapper_framebuffer_binding":@(wrapperFBO),@"native_draw_framebuffer_binding":@(nativeDraw),@"native_read_framebuffer_binding":@(nativeRead),
        @"host_native_framebuffer":@(TFMSurface.framebuffer),@"default_fbo_driver_binds":@(TFMDefaultFBDriverBinds),@"last_driver_bind_actual_fbo":@(TFMLastDriverFBO),
        @"last_sampled_draw_fbo":@(TFMLastDrawFBO),@"last_sampled_draw_program":@(TFMLastDrawProgram),@"native_current_program":@(program),@"native_renderbuffer_binding":@(renderbuffer),
        @"native_viewport":TFMIntegerVector(GL_VIEWPORT,4),@"native_scissor_box":TFMIntegerVector(GL_SCISSOR_BOX,4),@"native_scissor_enabled":@(glIsEnabled(GL_SCISSOR_TEST)),
        @"native_color_mask":@[@(mask[0]),@(mask[1]),@(mask[2]),@(mask[3])],@"native_clear_color":@[@(clear[0]),@(clear[1]),@(clear[2]),@(clear[3])],@"last_native_clear_mask":@(TFMLastClearMask),
        @"resolved_app_gl_procedures":TFMResolvedProcedures.copy ?: @[],@"wrapper_initialization_counter_baseline":TFMInitializationCounters ?: @{},
        @"diagnostic_scope":@"cumulative observed driver calls including GL4ES initialization; draw attempts and error observations do not prove correct game rendering; renderer error state is never drained"};
}
@implementation NSOpenGLContext
- (instancetype)initWithFormat:(NSOpenGLPixelFormat *)format shareContext:(NSOpenGLContext *)share {
    TFMGLMain();if (!format || share || TFMOwnedContext || TFMInitializationAttempted || !TFMFindHost()) {
        TFMGLRecord(@"context-rejected",@{@"reason":share?@"context sharing unsupported":@"format/host unavailable or one-context lifetime already used"});return nil;
    }
    self=[super init];if (!self) return nil;
    self.pixelFormat=format;self.tfmOpaque=YES;self.tfmSwapInterval=0;
    Class surfaceClass=NSClassFromString(@"TFMGLSurface");
    if (!surfaceClass || ![surfaceClass isSubclassOfClass:UIView.class]) return nil;
    EAGLContext *previous=EAGLContext.currentContext;
    TFMSurface=[[surfaceClass alloc] initWithFrame:CGRectMake(0,0,1,1)];
    TFMSurface.userInteractionEnabled=NO;[TFMHostWindow().rootViewController.view addSubview:TFMSurface];
    [TFMSurface layoutIfNeeded];
    BOOL bound=TFMBindSurface(NO);TFMNativeContext=TFMSurface.context;
    BOOL initialized=bound && TFMNativeContext && TFMInitializeWrapper();
    [EAGLContext setCurrentContext:previous];
    if (!initialized) { TFMGLRecord(@"context-create-failed",nil);return nil; }
    TFMOwnedContext=self;
    TFMGLRecord(@"context-created",@{@"native_fbo":@(TFMSurface.framebuffer),@"native_width":@(TFMSurface.drawableWidth),@"native_height":@(TFMSurface.drawableHeight)});
    return self;
}
+ (instancetype)currentContext { return EAGLContext.currentContext==TFMNativeContext?TFMCurrentContext:nil; }
+ (void)clearCurrentContext {
    TFMGLMain();if (![EAGLContext setCurrentContext:nil]) TFMGLStop(self,_cmd,@"EAGL clear-current failed");TFMCurrentContext=nil;
}
- (void)makeCurrentContext {
    TFMGLMain();if (self!=TFMOwnedContext || ![EAGLContext setCurrentContext:TFMNativeContext] || !TFMBindSurface(YES)) TFMGLStop(self,_cmd,@"native make-current failed");
    TFMCurrentContext=self;TFMGLRecord(@"context-current",nil);
}
- (void)setView:(id)view {
    TFMGLMain();if (!view) { _view=nil;[TFMSurface removeFromSuperview];TFMGLRecord(@"drawable-detached",nil);return; }
    UIView *native=TFMNativeView?TFMNativeView(view):nil;
    if (!native || !native.window || native.bounds.size.width<=0 || native.bounds.size.height<=0) TFMGLStop(self,_cmd,@"view has no nonempty native UIKit host");
    _view=view;[TFMSurface removeFromSuperview];TFMSurface.frame=native.bounds;
    TFMSurface.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [native addSubview:TFMSurface];[native layoutIfNeeded];
    EAGLContext *previous=EAGLContext.currentContext;
    if (![EAGLContext setCurrentContext:TFMNativeContext] || !TFMBindSurface(YES)) TFMGLStop(self,_cmd,@"drawable attach failed");
    [EAGLContext setCurrentContext:previous];
    TFMGLRecord(@"drawable-attached",@{@"native_width":@(TFMSurface.drawableWidth),@"native_height":@(TFMSurface.drawableHeight)});
}
- (void)update {
    TFMGLMain();if (!TFMSurface.window) return;
    EAGLContext *previous=EAGLContext.currentContext;
    if (![EAGLContext setCurrentContext:TFMNativeContext] || !TFMBindSurface(YES)) TFMGLStop(self,_cmd,@"drawable update failed");
    [EAGLContext setCurrentContext:previous];
}
- (void)clearDrawable { [self setView:nil]; }
- (void *)CGLContextObj { return (__bridge void *)self; }
- (void)setValues:(const int *)values forParameter:(int)parameter {
    int result=TFMCGLSetParameter((__bridge void *)self,parameter,values);
    if (result) TFMGLStop(self,_cmd,[NSString stringWithFormat:@"unsupported context parameter %d (CGL error %d)",parameter,result]);
}
- (void)getValues:(int *)values forParameter:(int)parameter {
    TFMGLMain();if (!values) TFMGLStop(self,_cmd,@"nil context value destination");
    if (parameter==SwapInterval) *values=self.tfmSwapInterval;
    else if (parameter==SurfaceOpacity) *values=self.tfmOpaque;
    else TFMGLStop(self,_cmd,@"unsupported context parameter query");
}
- (void)flushBuffer {
    TFMGLMain();if (NSOpenGLContext.currentContext!=self || !self.view) TFMGLStop(self,_cmd,@"present requires current attached drawable");
    GLint framebuffer=0,renderbuffer=0;TFMWrapperGetInteger(GL_FRAMEBUFFER_BINDING,&framebuffer);TFMWrapperGetInteger(GL_RENDERBUFFER_BINDING,&renderbuffer);
    TFMWrapperFlush();
    BOOL snapshot=TFMPresents<3 || !((TFMPresents+1)%120);
    NSDictionary *graphics=snapshot?TFMGraphicsSnapshot(framebuffer):nil;
    NSDictionary *pixels=snapshot && TFMPresents<3600?TFMNativePixelSamples():nil;
    TFMRawBindRenderbuffer(GL_RENDERBUFFER,TFMSurface.colorRenderbuffer);
    BOOL presented;
    if (self.tfmSwapInterval==1) {
        NSInteger fps=TFMHostWindow().screen.maximumFramesPerSecond;
        if (fps<=0) TFMGLStop(self,_cmd,@"no native display cadence available");
        presented=[TFMNativeContext presentRenderbuffer:GL_RENDERBUFFER afterMinimumDuration:1.0/(double)fps];
    } else presented=[TFMNativeContext presentRenderbuffer:GL_RENDERBUFFER];
    TFMWrapperBindFramebuffer(GL_FRAMEBUFFER,(GLuint)framebuffer);TFMWrapperBindRenderbuffer(GL_RENDERBUFFER,(GLuint)renderbuffer);
    if (!presented) TFMGLStop(self,_cmd,@"native EAGL presentation failed");
    TFMPresents++;NSUInteger frames=(NSUInteger)TFMPresents;
    if (frames<=3 || !(frames%120)) {
        NSMutableDictionary *fields=[@{@"native_presents":@(frames)} mutableCopy];
        if (graphics) fields[@"graphics_observation"]=graphics;
        if (pixels) fields[@"host_pixel_sample"]=pixels;
        if (frames<=3) {
            char marker; uintptr_t top=(uintptr_t)pthread_get_stackaddr_np(pthread_self());
            fields[@"thread_stack_bytes"]=@(pthread_get_stacksize_np(pthread_self()));
            fields[@"approximate_stack_used_bytes"]=@(top-(uintptr_t)&marker);
            void *addresses[40]; int count=backtrace(addresses,40); NSMutableArray *trace=[NSMutableArray array];
            for (int i=0;i<count;i++) {
                Dl_info info={0}; dladdr(addresses[i],&info);
                [trace addObject:@{@"image":info.dli_fname?@(info.dli_fname).lastPathComponent:@"unknown",
                    @"offset":@((uintptr_t)addresses[i]-(uintptr_t)info.dli_fbase),
                    @"symbol":info.dli_sname?@(info.dli_sname):@"stripped"}];
            }
            fields[@"present_call_stack"]=trace;
            fprintf(stderr,"TFM_STACK bytes=%lu approximate_used=%lu frames=%d\n",(unsigned long)pthread_get_stacksize_np(pthread_self()),(unsigned long)(top-(uintptr_t)&marker),count);
        }
        TFMGLRecord(@"native-presented",fields);
    }
}
@end

int TFMCGLSetParameter(void *context,int parameter,const int *values) {
    if (!NSThread.isMainThread) return CGLBadState;
    if (!TFMOwnedContext || context!=(__bridge void *)TFMOwnedContext) return CGLBadContext;
    if (!values) return CGLBadValue;
    if (parameter==SwapInterval) {
        if (*values!=0 && *values!=1) return CGLBadValue;
        TFMOwnedContext.tfmSwapInterval=*values;
        TFMGLRecord(@"swap-pacing-configured",@{@"swap_interval":@(*values),@"semantics":@"0 native immediate request; 1 native EAGL minimum display duration from screen max cadence; desktop exact retrace phase unverified"});
        return CGLNoError;
    }
    if (parameter==SurfaceOpacity) {
        if (*values!=0 && *values!=1) return CGLBadValue;
        TFMOwnedContext.tfmOpaque=*values!=0;TFMSurface.opaque=*values!=0;TFMSurface.layer.opaque=*values!=0;
        return CGLNoError;
    }
    TFMGLRecord(@"cgl-parameter-rejected",@{@"parameter":@(parameter),@"cgl_error":@(CGLBadEnumeration)});
    return CGLBadEnumeration;
}
void *TFMOpenGLGetProcAddress(const char *name) {
    TFMGLMain();if (!name || strncmp(name,"gl",2) || !TFMInitialized || NSOpenGLContext.currentContext!=TFMOwnedContext) return NULL;
    void *procedure=TFMResolver(name);
    if (!TFMResolvedProcedures) TFMResolvedProcedures=[NSMutableArray array];
    NSString *key=@(name);if (TFMResolvedProcedures.count<256 && ![TFMResolvedProcedures containsObject:key]) [TFMResolvedProcedures addObject:key];
    if (procedure && !strcmp(name,"glGetError") && TFMWrapperGetError) return TFMApplicationGetError;
    if (procedure && !strcmp(name,"glGetIntegerv") && TFMWrapperGetInteger) return TFMApplicationGetInteger;
    if (procedure && TFMWrapperDeleteFramebuffers && (!strcmp(name,"glDeleteFramebuffers") || !strcmp(name,"glDeleteFramebuffersEXT") || !strcmp(name,"glDeleteFramebuffersARB"))) return TFMApplicationDeleteFramebuffers;
    if (procedure && TFMWrapperRenderbufferStorage && (!strcmp(name,"glRenderbufferStorage") || !strcmp(name,"glRenderbufferStorageEXT"))) return TFMApplicationRenderbufferStorage;
    if (procedure && TFMWrapperRenderbufferStorageMultisample && (!strcmp(name,"glRenderbufferStorageMultisample") || !strcmp(name,"glRenderbufferStorageMultisampleEXT"))) return TFMApplicationRenderbufferStorageMultisample;
    return procedure;
}
NSDictionary *TFMOpenGLStatus(void) {
    TFMGLMain();return @{@"initialized":@(TFMInitialized),@"context_created":@(TFMOwnedContext!=nil),
        @"current":@(NSOpenGLContext.currentContext!=nil),@"actual_target":@"GL4ES desktop OpenGL 2.1 over native EAGL ES3",
        @"core_3_2_supported":@NO,@"core_4_1_supported":@NO,
        @"limitations":@[@"single main-thread context, sharing and multisample drawable unsupported",
            @"legacy format is selected only after genuine core-profile rejection",
            @"swap interval1 requests native minimum display duration, not exact desktop retrace phase",
            @"GL4ES/native surface images retained for process lifetime; no reinitialization or teardown API",
            @"native presentation is not proof that the game drew correct content"]};
}
