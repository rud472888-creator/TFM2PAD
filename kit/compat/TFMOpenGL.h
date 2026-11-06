#pragma once
#import <Foundation/Foundation.h>

// Main-thread, one-context diagnostic bridge: GL4ES desktop GL 2.1 over real
// EAGL ES3. Core 3.2/4.1 pixel formats are rejected, permitting glutin's existing
// legacy fallback. No desktop GL4 feature level is advertised by this adapter.
FOUNDATION_EXPORT void *TFMOpenGLGetProcAddress(const char *name);
FOUNDATION_EXPORT NSDictionary *TFMOpenGLStatus(void);
FOUNDATION_EXPORT int TFMCGLSetParameter(void *context,int parameter,const int *values) __asm__("_CGLSetParameter");
