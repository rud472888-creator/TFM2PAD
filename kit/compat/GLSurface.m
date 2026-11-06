// Original UIKit/EAGL foundation; no desktop OpenGL compatibility is claimed.
#import "GLSurface.h"
#import <QuartzCore/CAEAGLLayer.h>
#include <stdlib.h>

static BOOL TFMGLFail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"TFMGLSurface" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

@interface TFMGLSurface ()
@property(nonatomic, readwrite, strong) EAGLContext *context;
@property(nonatomic, readwrite) GLuint framebuffer;
@property(nonatomic, readwrite) GLuint colorRenderbuffer;
@property(nonatomic, readwrite) GLuint depthStencilRenderbuffer;
@property(nonatomic, readwrite) GLint drawableWidth;
@property(nonatomic, readwrite) GLint drawableHeight;
@property(nonatomic) BOOL storageDirty;
@property(nonatomic) CGSize allocatedPointSize;
@property(nonatomic) CGFloat allocatedScale;
@end

@implementation TFMGLSurface
+ (Class)layerClass { return CAEAGLLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = YES;
        self.userInteractionEnabled = NO;
        CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
        layer.opaque = YES;
        layer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
        self.storageDirty = YES;
    }
    return self;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    UIScreen *screen = self.window.windowScene.screen ?: self.window.screen;
    if (screen) self.contentScaleFactor = screen.scale;
    self.storageDirty = YES;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(self.bounds.size, self.allocatedPointSize) || self.contentScaleFactor != self.allocatedScale)
        self.storageDirty = YES;
}
- (BOOL)bindDrawable:(NSError **)error {
    if (!NSThread.isMainThread) return TFMGLFail(error, 1, @"GL surface calls require the main thread");
    if (!self.window || self.bounds.size.width <= 0 || self.bounds.size.height <= 0)
        return TFMGLFail(error, 2, @"A nonempty surface attached to a visible window is required");
    if (!self.context) self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!self.context) return TFMGLFail(error, 3, @"Device could not create a native OpenGL ES 3 context");
    if (![EAGLContext setCurrentContext:self.context]) return TFMGLFail(error, 4, @"Could not make the ES3 context current");
    if (!self.framebuffer) {
        GLuint framebuffer = 0, color = 0, depth = 0;
        glGenFramebuffers(1, &framebuffer);
        glGenRenderbuffers(1, &color);
        glGenRenderbuffers(1, &depth);
        self.framebuffer = framebuffer;
        self.colorRenderbuffer = color;
        self.depthStencilRenderbuffer = depth;
        self.storageDirty = YES;
    }
    if (!CGSizeEqualToSize(self.bounds.size, self.allocatedPointSize) || self.contentScaleFactor != self.allocatedScale)
        self.storageDirty = YES;
    glBindFramebuffer(GL_FRAMEBUFFER, self.framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);
    if (self.storageDirty) {
        if (![self.context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer])
            return TFMGLFail(error, 5, @"EAGL could not allocate CAEAGLLayer color storage");
        GLint width = 0, height = 0;
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
        if (width <= 0 || height <= 0) return TFMGLFail(error, 6, @"Drawable returned empty backing dimensions");
        self.drawableWidth = width;
        self.drawableHeight = height;
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self.colorRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, self.depthStencilRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, self.depthStencilRenderbuffer);
        self.allocatedPointSize = self.bounds.size;
        self.allocatedScale = self.contentScaleFactor;
    }
    GLenum framebufferStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    // glGetError consumes context-global caller state. A renderer may already
    // have a pending error when it asks us to bind an otherwise complete drawable.
    // Validate this operation through EAGL results, dimensions and FBO status;
    // leave the GL error flag available for its actual owner to inspect.
    if (framebufferStatus != GL_FRAMEBUFFER_COMPLETE)
        return TFMGLFail(error, 7, [NSString stringWithFormat:@"Framebuffer status 0x%x", framebufferStatus]);
    self.storageDirty = NO;
    glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);
    return YES;
}
- (BOOL)presentDrawable:(NSError **)error {
    if (!NSThread.isMainThread) return TFMGLFail(error, 1, @"GL surface calls require the main thread");
    if (!self.context || !self.colorRenderbuffer || self.storageDirty)
        return TFMGLFail(error, 8, @"Bind and render the drawable before presenting");
    EAGLContext *previous = EAGLContext.currentContext;
    BOOL bound = [EAGLContext setCurrentContext:self.context];
    BOOL presented = NO;
    if (bound) {
        glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);
        presented = [self.context presentRenderbuffer:GL_RENDERBUFFER];
    }
    BOOL restored = [EAGLContext setCurrentContext:previous];
    if (!bound || !presented || !restored) return TFMGLFail(error, 9, @"EAGL bind, present, or context restoration failed");
    return YES;
}
- (void)invalidate {
    if (!NSThread.isMainThread) return;
    EAGLContext *previous = EAGLContext.currentContext;
    EAGLContext *owned = self.context;
    if (owned && [EAGLContext setCurrentContext:owned]) {
        GLuint framebuffer = self.framebuffer, color = self.colorRenderbuffer, depth = self.depthStencilRenderbuffer;
        if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
        if (color) glDeleteRenderbuffers(1, &color);
        if (depth) glDeleteRenderbuffers(1, &depth);
    }
    self.framebuffer = self.colorRenderbuffer = self.depthStencilRenderbuffer = 0;
    self.drawableWidth = self.drawableHeight = 0;
    self.storageDirty = YES;
    self.context = nil;
    [EAGLContext setCurrentContext:previous == owned ? nil : previous];
}
- (void)dealloc {
    // UIKit callers must release/invalidate views on the main thread.
    if (NSThread.isMainThread) [self invalidate];
}
@end

static NSString *TFMGLString(GLenum name) {
    const GLubyte *value = glGetString(name);
    return value ? [NSString stringWithUTF8String:(const char *)value] : @"unavailable";
}

static GLuint TFMGLCompile(GLenum type, const char *source, NSString **failure) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled) return shader;
    GLint size = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &size);
    NSMutableData *log = [NSMutableData dataWithLength:MAX(size, 1)];
    GLsizei written = 0;
    glGetShaderInfoLog(shader, (GLsizei)log.length, &written, log.mutableBytes);
    if (failure) *failure = [[NSString alloc] initWithBytes:log.bytes length:(NSUInteger)MAX(written, 0) encoding:NSUTF8StringEncoding] ?: @"Shader compilation failed";
    glDeleteShader(shader);
    return 0;
}

static GLuint TFMGLTriangleProgram(NSString **failure) {
    const char *vertex = "#version 300 es\nprecision highp float;\nconst vec2 p[3]=vec2[3](vec2(-0.75,-0.75),vec2(0.75,-0.75),vec2(0.0,0.75));\nvoid main(){gl_Position=vec4(p[gl_VertexID],0.0,1.0);}\n";
    const char *fragment = "#version 300 es\nprecision highp float;\nout vec4 color;\nvoid main(){color=vec4(1.0,0.0,0.0,1.0);}\n";
    GLuint vs = TFMGLCompile(GL_VERTEX_SHADER, vertex, failure);
    if (!vs) return 0;
    GLuint fs = TFMGLCompile(GL_FRAGMENT_SHADER, fragment, failure);
    if (!fs) { glDeleteShader(vs); return 0; }
    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked) return program;
    GLint size = 0;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &size);
    NSMutableData *log = [NSMutableData dataWithLength:MAX(size, 1)];
    GLsizei written = 0;
    glGetProgramInfoLog(program, (GLsizei)log.length, &written, log.mutableBytes);
    if (failure) *failure = [[NSString alloc] initWithBytes:log.bytes length:(NSUInteger)MAX(written, 0) encoding:NSUTF8StringEncoding] ?: @"Program link failed";
    glDeleteProgram(program);
    return 0;
}

// Isolated original diagnostic shaders; these never contain game shader code.
// Compilation establishes grammar/builtin availability only, not a correct
// implementation of the game's complete shader or interpolation semantics.
static NSDictionary *TFMGLCapabilityProbe(const char *fragmentSource) {
    NSString *failure = nil;
    GLuint shader = TFMGLCompile(GL_FRAGMENT_SHADER, fragmentSource, &failure);
    BOOL compiled = shader != 0;
    if (shader) glDeleteShader(shader);
    return @{@"compiles": @(compiled), @"method": @"fragment_shader_compile_only", @"shader_version": @"300 es", @"compiler_log": failure ?: @""};
}

static void TFMGLTest(NSMutableArray *tests, NSString *name, BOOL pass, NSString *detail) {
    [tests addObject:@{@"name": name, @"status": pass ? @"pass" : @"fail", @"detail": detail ?: @""}];
}
static NSArray *TFMGLPixel(const GLubyte *pixel) { return @[@(pixel[0]), @(pixel[1]), @(pixel[2]), @(pixel[3])]; }
static BOOL TFMGLPixelNear(const GLubyte *pixel, int red, int green, int blue, int alpha) {
    return abs((int)pixel[0] - red) <= 2 && abs((int)pixel[1] - green) <= 2 && abs((int)pixel[2] - blue) <= 2 && abs((int)pixel[3] - alpha) <= 2;
}

NSDictionary *TFMGLSurfaceSmokeTest(UIView *hostView) {
    NSMutableDictionary *report = [@{@"backend": @"Native EAGL OpenGL ES 3", @"limitations": @[@"This validates an ES3 drawable, a simple ES3 triangle and the pending-error ownership regression.", @"This smoke test does not validate desktop OpenGL 4.1, the NSOpenGL bridge, the original game renderer or a runnable port.", @"The temporary visible surface is removed after testing."]} mutableCopy];
    NSMutableArray *tests = [NSMutableArray array];
    if (!NSThread.isMainThread || !hostView.window || hostView.bounds.size.width < 32 || hostView.bounds.size.height < 32) {
        report[@"status"] = @"fail";
        report[@"reason"] = @"A visible host view on the main thread with at least 32x32 points is required";
        return report;
    }
    EAGLContext *previous = EAGLContext.currentContext;
    TFMGLSurface *surface = nil;
    GLuint program = 0, vao = 0;
    @try {
        do {
            CGFloat width = MIN(96, hostView.bounds.size.width / 2);
            CGFloat height = MIN(96, hostView.bounds.size.height);
            surface = [[TFMGLSurface alloc] initWithFrame:CGRectMake(0, 0, width, height)];
            [hostView addSubview:surface];
            [surface layoutIfNeeded];
            NSError *error = nil;
            BOOL created = [surface bindDrawable:&error];
            TFMGLTest(tests, @"es3_context_and_drawable", created, error.localizedDescription ?: @"Created ES3 context and complete color/depth-stencil framebuffer");
            if (!created) break;
            // This test owns this newly created context. Check its initial state
            // explicitly, then act as a caller carrying a known pending error.
            // No glGetError is allowed between injection and bindDrawable.
            GLenum initialError = glGetError();
            TFMGLTest(tests, @"drawable_initial_error_state", initialError == GL_NO_ERROR, [NSString stringWithFormat:@"New test context error before injection: 0x%x", initialError]);
            if (initialError != GL_NO_ERROR) break;
            glEnable((GLenum)0xffffffffu); // Invalid capability: GL_INVALID_ENUM.
            error = nil;
            BOOL reboundWithPendingError = [surface bindDrawable:&error];
            GLenum pendingFramebufferStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            GLenum callerError = glGetError();
            GLenum callerNextError = glGetError();
            BOOL pendingErrorPreserved = reboundWithPendingError && pendingFramebufferStatus == GL_FRAMEBUFFER_COMPLETE && callerError == GL_INVALID_ENUM && callerNextError == GL_NO_ERROR;
            report[@"pending_error_preservation"] = @{@"bind_succeeded": @(reboundWithPendingError), @"framebuffer_status": @(pendingFramebufferStatus), @"caller_first_error": @(callerError), @"expected_first_error": @(GL_INVALID_ENUM), @"caller_next_error": @(callerNextError), @"expected_next_error": @(GL_NO_ERROR)};
            TFMGLTest(tests, @"bind_preserves_callers_pending_gl_error", pendingErrorPreserved, [NSString stringWithFormat:@"Complete drawable rebound=%d FBO=0x%x; caller errors 0x%x then 0x%x. %@", reboundWithPendingError, pendingFramebufferStatus, callerError, callerNextError, error.localizedDescription ?: @""]);
            if (!pendingErrorPreserved) break;
            report[@"gl_version"] = TFMGLString(GL_VERSION);
            report[@"gl_renderer"] = TFMGLString(GL_RENDERER);
            report[@"gl_vendor"] = TFMGLString(GL_VENDOR);
            report[@"gl_shading_language_version"] = TFMGLString(GL_SHADING_LANGUAGE_VERSION);
            GLint majorVersion = 0, minorVersion = 0, extensionCount = 0;
            glGetIntegerv(GL_MAJOR_VERSION, &majorVersion);
            glGetIntegerv(GL_MINOR_VERSION, &minorVersion);
            glGetIntegerv(GL_NUM_EXTENSIONS, &extensionCount);
            NSMutableArray *extensions = [NSMutableArray array];
            for (GLint index = 0; index < extensionCount; index++) {
                const GLubyte *name = glGetStringi(GL_EXTENSIONS, (GLuint)index);
                if (name) [extensions addObject:[NSString stringWithUTF8String:(const char *)name]];
            }
            GLenum extensionError = glGetError();
            [extensions sortUsingSelector:@selector(compare:)];
            report[@"gl_major_version"] = @(majorVersion);
            report[@"gl_minor_version"] = @(minorVersion);
            report[@"gl_extension_count"] = @(extensionCount);
            report[@"gl_extensions"] = extensions;
            report[@"gl_extensions_query_error"] = @(extensionError);
            TFMGLTest(tests, @"es3_extension_enumeration", majorVersion >= 3 && extensionCount >= 0 && (NSUInteger)extensionCount == extensions.count && extensionError == GL_NO_ERROR, @"Complete extension names read through ES3 glGetStringi; true version integers queried");
            report[@"shader_capability_probes"] = @{
                @"noperspective_nv_extension_advertised": @([extensions containsObject:@"GL_NV_shader_noperspective_interpolation"]),
                @"glsl_es300_fma": TFMGLCapabilityProbe("#version 300 es\nprecision highp float;\nuniform float x;out vec4 color;\nvoid main(){color=vec4(fma(x,0.5,0.25));}\n"),
                @"glsl_es300_ldexp": TFMGLCapabilityProbe("#version 300 es\nprecision highp float;\nuniform float x;out vec4 color;\nvoid main(){color=vec4(ldexp(x,2));}\n"),
                @"glsl_es300_noperspective_nv": TFMGLCapabilityProbe("#version 300 es\n#extension GL_NV_shader_noperspective_interpolation : require\nprecision highp float;\nnoperspective in vec2 uv;out vec4 color;\nvoid main(){color=vec4(uv,0.0,1.0);}\n"),
                @"limitations": @"Independent compilation probes; no link, execution, derivative, precision, or game shader correctness claim"
            };
            report[@"initial_drawable_pixels"] = @[@(surface.drawableWidth), @(surface.drawableHeight)];
            GLint initialWidth = surface.drawableWidth;
            surface.frame = CGRectMake(0, 0, MIN(width + 32, hostView.bounds.size.width), height);
            [surface setNeedsLayout];
            [surface layoutIfNeeded];
            error = nil;
            BOOL resized = [surface bindDrawable:&error] && surface.drawableWidth > initialWidth;
            TFMGLTest(tests, @"drawable_resize", resized, error.localizedDescription ?: @"Color and depth/stencil storage resized to larger UIKit surface");
            report[@"drawable_pixels"] = @[@(surface.drawableWidth), @(surface.drawableHeight)];
            if (!resized) break;
            GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            report[@"framebuffer_status"] = @(status);
            TFMGLTest(tests, @"framebuffer_complete", status == GL_FRAMEBUFFER_COMPLETE, [NSString stringWithFormat:@"0x%x", status]);
            if (status != GL_FRAMEBUFFER_COMPLETE) break;
            NSString *shaderFailure = nil;
            program = TFMGLTriangleProgram(&shaderFailure);
            TFMGLTest(tests, @"gles3_shader_compile_and_link", program != 0, shaderFailure ?: @"Compiled #version 300 es vertex/fragment shaders");
            if (!program) break;
            glGenVertexArrays(1, &vao);
            glBindVertexArray(vao);
            glViewport(0, 0, surface.drawableWidth, surface.drawableHeight);
            glDisable(GL_BLEND); glDisable(GL_DITHER); glDisable(GL_SCISSOR_TEST);
            glDisable(GL_DEPTH_TEST); glDisable(GL_STENCIL_TEST); glDisable(GL_CULL_FACE);
            glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
            glClearColor(0, 0, 1, 1);
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
            glUseProgram(program);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glFinish();
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            GLubyte center[4] = {0}, background[4] = {0};
            GLint centerX = surface.drawableWidth / 2, centerY = surface.drawableHeight / 2;
            glReadPixels(centerX, centerY, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, center);
            glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, background);
            GLenum readError = glGetError();
            report[@"pixels"] = @{@"center": TFMGLPixel(center), @"background": TFMGLPixel(background), @"center_xy": @[@(centerX), @(centerY)], @"background_xy": @[@2, @2], @"tolerance_per_channel": @2, @"expected_center": @[@255, @0, @0, @255], @"expected_background": @[@0, @0, @255, @255]};
            report[@"render_read_gl_error"] = @(readError);
            TFMGLTest(tests, @"triangle_center_pixel", readError == GL_NO_ERROR && TFMGLPixelNear(center, 255, 0, 0, 255), @"Center is inside the red triangle; RGBA8 channels within tolerance 2");
            TFMGLTest(tests, @"clear_background_pixel", readError == GL_NO_ERROR && TFMGLPixelNear(background, 0, 0, 255, 255), @"Bottom-left sample is outside triangle and remains blue");
            error = nil;
            BOOL presented = [surface presentDrawable:&error];
            TFMGLTest(tests, @"eagl_present", presented, error.localizedDescription ?: @"EAGL presented the actual CAEAGLLayer color renderbuffer");
        } while (0);
    } @catch (NSException *exception) {
        TFMGLTest(tests, @"unexpected_exception", NO, [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
    } @finally {
        if (surface.context && [EAGLContext setCurrentContext:surface.context]) {
            if (program) glDeleteProgram(program);
            if (vao) glDeleteVertexArrays(1, &vao);
        }
        [surface invalidate];
        BOOL invalidated = !surface.context && surface.framebuffer == 0 && surface.colorRenderbuffer == 0 && surface.depthStencilRenderbuffer == 0 && surface.drawableWidth == 0 && surface.drawableHeight == 0;
        [surface removeFromSuperview];
        TFMGLTest(tests, @"surface_resource_teardown", invalidated && !surface.superview, @"Owned context and GL object names cleared; temporary view removed");
        BOOL restored = [EAGLContext setCurrentContext:previous] && EAGLContext.currentContext == previous;
        TFMGLTest(tests, @"previous_eagl_context_restored", restored, @"Previous current context restored after teardown, including failure paths");
    }
    NSUInteger passed = 0;
    for (NSDictionary *test in tests) if ([test[@"status"] isEqual:@"pass"]) passed++;
    report[@"tests"] = tests;
    report[@"passed"] = @(passed);
    report[@"failed"] = @(tests.count - passed);
    report[@"status"] = passed == tests.count ? @"pass" : @"fail";
    return report;
}
