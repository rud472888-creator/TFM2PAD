#import <UIKit/UIKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

// Native OpenGL ES 3 drawable foundation, not a desktop OpenGL 4.1 adapter.
// All lifecycle and rendering calls require the main thread. The surface owns
// its EAGLContext, framebuffer, color renderbuffer, and depth/stencil buffer.
@interface TFMGLSurface : UIView
@property(nonatomic, readonly, strong) EAGLContext *context;
@property(nonatomic, readonly) GLuint framebuffer;
@property(nonatomic, readonly) GLuint colorRenderbuffer;
@property(nonatomic, readonly) GLuint depthStencilRenderbuffer;
@property(nonatomic, readonly) GLint drawableWidth;
@property(nonatomic, readonly) GLint drawableHeight;

// Lazily creates an ES3 context, resizes storage when necessary, makes this
// context current, and binds the complete framebuffer. Caller owns GL state and
// must restore any previous EAGLContext after rendering.
// This helper never calls glGetError or attributes a pending caller error to the
// drawable. EAGL return values, nonzero backing dimensions and framebuffer
// completeness determine its result; the renderer retains its GL error state.
- (BOOL)bindDrawable:(NSError **)error;
// Presents the color renderbuffer; preserves the context current on entry.
- (BOOL)presentDrawable:(NSError **)error;
// Explicitly releases owned GL resources. If this context was current, clears
// it; otherwise preserves the previous context. The view can be bound again.
- (void)invalidate;
@end

// Requires a visible host view on the main thread. Temporarily adds a surface,
// verifies that binding preserves an injected caller GL_INVALID_ENUM, checks
// resize, draws a real ES3 triangle, reads foreground/background pixels,
// presents, and removes it. Restores the caller's current EAGLContext on exit.
NSDictionary *TFMGLSurfaceSmokeTest(UIView *hostView);
