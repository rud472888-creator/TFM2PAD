#import "GLSurface.h"

typedef void *(*TFMGL4ESFunctionResolver)(const char *name);

// Main thread only. GL4ES must already be initialized for surface.context,
// which must be current, with a prepared drawable. No original Skia object may
// be using the context concurrently. Owns and deletes its offscreen resources;
// does not close GL4ES, invalidate the host surface, or call original game code.
NSDictionary *TFMGL4ESRenderProbe(TFMGL4ESFunctionResolver resolver, TFMGLSurface *surface);
