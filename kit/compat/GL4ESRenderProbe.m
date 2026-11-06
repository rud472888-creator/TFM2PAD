#import "GL4ESRenderProbe.h"
#include <stdlib.h>

typedef struct {
#define W(F) __typeof__(&F) F;
    W(glGetIntegerv) W(glGetFloatv) W(glGetBooleanv) W(glGetError) W(glIsEnabled)
    W(glGenTextures) W(glBindTexture) W(glTexParameteri) W(glTexImage2D) W(glDeleteTextures) W(glActiveTexture)
    W(glGenFramebuffers) W(glBindFramebuffer) W(glFramebufferTexture2D) W(glCheckFramebufferStatus) W(glDeleteFramebuffers)
    W(glCreateShader) W(glShaderSource) W(glCompileShader) W(glGetShaderiv) W(glGetShaderInfoLog) W(glDeleteShader)
    W(glCreateProgram) W(glAttachShader) W(glBindAttribLocation) W(glLinkProgram) W(glGetProgramiv) W(glGetProgramInfoLog) W(glUseProgram) W(glDeleteProgram)
    W(glGenBuffers) W(glBindBuffer) W(glBufferData) W(glDeleteBuffers)
    W(glGetVertexAttribiv) W(glGetVertexAttribPointerv) W(glVertexAttribPointer) W(glEnableVertexAttribArray) W(glDisableVertexAttribArray)
    W(glViewport) W(glEnable) W(glDisable) W(glColorMask) W(glClearColor) W(glClear) W(glDrawArrays) W(glFinish) W(glReadPixels) W(glPixelStorei)
#undef W
} TFMGL4ESAPI;

static void Check(NSMutableArray *tests, NSString *name, BOOL success, NSString *detail) {
    [tests addObject:@{@"name": name, @"status": success ? @"pass" : @"fail", @"detail": detail ?: @""}];
}
static NSArray *Pixel(const GLubyte *p) { return @[@(p[0]), @(p[1]), @(p[2]), @(p[3])]; }
static BOOL Matches(const GLubyte *p, int r, int g, int b) {
    return abs((int)p[0]-r) <= 2 && abs((int)p[1]-g) <= 2 && abs((int)p[2]-b) <= 2 && abs((int)p[3]-255) <= 2;
}
static NSArray *DrainErrors(GLenum (*getError)(void)) {
    NSMutableArray *errors = [NSMutableArray array];
    for (int i=0; i<32; i++) { GLenum error=getError(); if (error==GL_NO_ERROR) break; [errors addObject:@(error)]; }
    return errors;
}
static NSString *ShaderLog(TFMGL4ESAPI *a, GLuint object, BOOL program) {
    GLint length=0; GLsizei written=0;
    if (program) a->glGetProgramiv(object,GL_INFO_LOG_LENGTH,&length);
    else a->glGetShaderiv(object,GL_INFO_LOG_LENGTH,&length);
    NSMutableData *data=[NSMutableData dataWithLength:MAX(length,1)];
    if (program) a->glGetProgramInfoLog(object,(GLsizei)data.length,&written,data.mutableBytes);
    else a->glGetShaderInfoLog(object,(GLsizei)data.length,&written,data.mutableBytes);
    return [[NSString alloc] initWithBytes:data.bytes length:(NSUInteger)MAX(written,0) encoding:NSUTF8StringEncoding] ?: @"";
}
static GLuint Compile(TFMGL4ESAPI *a, GLenum type, const GLchar *source, NSMutableArray *logs) {
    GLuint shader=a->glCreateShader(type);
    if (!shader) return 0;
    a->glShaderSource(shader,1,&source,NULL); a->glCompileShader(shader);
    GLint compiled=0; a->glGetShaderiv(shader,GL_COMPILE_STATUS,&compiled);
    [logs addObject:@{@"stage": type==GL_VERTEX_SHADER ? @"vertex" : @"fragment", @"compiled": @(compiled!=0), @"log": ShaderLog(a,shader,NO)}];
    if (!compiled) { a->glDeleteShader(shader); return 0; }
    return shader;
}

NSDictionary *TFMGL4ESRenderProbe(TFMGL4ESFunctionResolver resolver, TFMGLSurface *surface) {
    NSMutableDictionary *report=[@{@"scope": @"Independent GLSL120 triangle through GL4ES, wrapper-owned offscreen texture/FBO, native GLES blit and EAGL presentation. No original Skia drawing or game main.",
        @"limitations": @[@"This simple shader/pixel test does not establish game shader or renderer compatibility.", @"Raw GLES is used for host state isolation and the explicit presentation bridge; triangle shaders/draw/texture/FBO/readback use wrapped desktop functions."]} mutableCopy];
    if (!NSThread.isMainThread || !resolver || !surface.context || EAGLContext.currentContext!=surface.context || !surface.framebuffer || surface.drawableWidth<8 || surface.drawableHeight<8) {
        report[@"status"]=@"fail"; report[@"reason"]=@"Need initialized GL4ES resolver and prepared surface with its EAGL context current on main thread"; return report;
    }
    TFMGL4ESAPI a={0}; NSMutableArray *missing=[NSMutableArray array];
#define LOAD(F) a.F=(__typeof__(a.F))resolver(#F); if (!a.F) [missing addObject:@#F];
    LOAD(glGetIntegerv) LOAD(glGetFloatv) LOAD(glGetBooleanv) LOAD(glGetError) LOAD(glIsEnabled)
    LOAD(glGenTextures) LOAD(glBindTexture) LOAD(glTexParameteri) LOAD(glTexImage2D) LOAD(glDeleteTextures) LOAD(glActiveTexture)
    LOAD(glGenFramebuffers) LOAD(glBindFramebuffer) LOAD(glFramebufferTexture2D) LOAD(glCheckFramebufferStatus) LOAD(glDeleteFramebuffers)
    LOAD(glCreateShader) LOAD(glShaderSource) LOAD(glCompileShader) LOAD(glGetShaderiv) LOAD(glGetShaderInfoLog) LOAD(glDeleteShader)
    LOAD(glCreateProgram) LOAD(glAttachShader) LOAD(glBindAttribLocation) LOAD(glLinkProgram) LOAD(glGetProgramiv) LOAD(glGetProgramInfoLog) LOAD(glUseProgram) LOAD(glDeleteProgram)
    LOAD(glGenBuffers) LOAD(glBindBuffer) LOAD(glBufferData) LOAD(glDeleteBuffers)
    LOAD(glGetVertexAttribiv) LOAD(glGetVertexAttribPointerv) LOAD(glVertexAttribPointer) LOAD(glEnableVertexAttribArray) LOAD(glDisableVertexAttribArray)
    LOAD(glViewport) LOAD(glEnable) LOAD(glDisable) LOAD(glColorMask) LOAD(glClearColor) LOAD(glClear) LOAD(glDrawArrays) LOAD(glFinish) LOAD(glReadPixels) LOAD(glPixelStorei)
#undef LOAD
    if (missing.count) { report[@"status"]=@"fail"; report[@"missing_wrapper_functions"]=missing; return report; }
    NSMutableArray *tests=[NSMutableArray array], *shaderLogs=[NSMutableArray array];
    report[@"preexisting_wrapper_errors"]=DrainErrors(a.glGetError);
    report[@"preexisting_native_errors"]=DrainErrors(glGetError);
    const GLenum caps[]={GL_BLEND,GL_DITHER,GL_DEPTH_TEST,GL_STENCIL_TEST,GL_SCISSOR_TEST,GL_CULL_FACE};
    GLboolean oldCaps[6], nativeCaps[6], oldMask[4], nativeMask[4];
    GLfloat oldClear[4], nativeClear[4];
    GLint oldViewport[4], nativeViewport[4], oldProgram=0, oldFBO=0, oldReadFBO=0, oldBuffer=0, oldActive=0, oldTexture0=0, oldPack=0, oldUnpack=0;
    GLint nativeProgram=0,nativeVAO=0,nativeArrayBuffer=0,nativeActive=0,nativeTexture0=0,nativeRead=0,nativeDraw=0,nativeRBO=0,nativeReadBuffer=0,nativePack=0,nativeUnpack=0;
    GLint attribEnabled=0,attribSize=4,attribType=GL_FLOAT,attribNormalized=0,attribStride=0,attribBuffer=0;
    void *attribPointer=NULL;
    a.glGetIntegerv(GL_VIEWPORT,oldViewport); a.glGetIntegerv(GL_CURRENT_PROGRAM,&oldProgram);
    a.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&oldFBO); a.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&oldReadFBO);
    a.glGetIntegerv(GL_ARRAY_BUFFER_BINDING,&oldBuffer); a.glGetIntegerv(GL_ACTIVE_TEXTURE,&oldActive);
    a.glGetIntegerv(GL_PACK_ALIGNMENT,&oldPack); a.glGetIntegerv(GL_UNPACK_ALIGNMENT,&oldUnpack);
    a.glGetFloatv(GL_COLOR_CLEAR_VALUE,oldClear); a.glGetBooleanv(GL_COLOR_WRITEMASK,oldMask);
    for (int i=0;i<6;i++) { oldCaps[i]=a.glIsEnabled(caps[i]); nativeCaps[i]=glIsEnabled(caps[i]); }
    a.glGetVertexAttribiv(0,GL_VERTEX_ATTRIB_ARRAY_ENABLED,&attribEnabled); a.glGetVertexAttribiv(0,GL_VERTEX_ATTRIB_ARRAY_SIZE,&attribSize);
    a.glGetVertexAttribiv(0,GL_VERTEX_ATTRIB_ARRAY_TYPE,&attribType); a.glGetVertexAttribiv(0,GL_VERTEX_ATTRIB_ARRAY_NORMALIZED,&attribNormalized);
    a.glGetVertexAttribiv(0,GL_VERTEX_ATTRIB_ARRAY_STRIDE,&attribStride); a.glGetVertexAttribiv(0,GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING,&attribBuffer);
    a.glGetVertexAttribPointerv(0,GL_VERTEX_ATTRIB_ARRAY_POINTER,&attribPointer);
    glGetIntegerv(GL_CURRENT_PROGRAM,&nativeProgram); glGetIntegerv(GL_VERTEX_ARRAY_BINDING,&nativeVAO); glGetIntegerv(GL_ARRAY_BUFFER_BINDING,&nativeArrayBuffer);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&nativeRead); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&nativeDraw);
    glGetIntegerv(GL_RENDERBUFFER_BINDING,&nativeRBO); glGetIntegerv(GL_READ_BUFFER,&nativeReadBuffer);
    glGetIntegerv(GL_VIEWPORT,nativeViewport); glGetIntegerv(GL_ACTIVE_TEXTURE,&nativeActive);
    glGetIntegerv(GL_PACK_ALIGNMENT,&nativePack); glGetIntegerv(GL_UNPACK_ALIGNMENT,&nativeUnpack);
    glGetFloatv(GL_COLOR_CLEAR_VALUE,nativeClear); glGetBooleanv(GL_COLOR_WRITEMASK,nativeMask);
    glActiveTexture(GL_TEXTURE0); glGetIntegerv(GL_TEXTURE_BINDING_2D,&nativeTexture0); glActiveTexture((GLenum)nativeActive);
    a.glActiveTexture(GL_TEXTURE0); a.glGetIntegerv(GL_TEXTURE_BINDING_2D,&oldTexture0);
    GLuint texture=0,fbo=0,buffer=0,program=0,vs=0,fs=0,isolatedNativeVAO=0;
    BOOL snapshotOK=NO;
    @try {
        do {
            NSArray *snapshotErrors=DrainErrors(a.glGetError);
            report[@"state_snapshot_errors"]=snapshotErrors;
            snapshotOK=snapshotErrors.count==0;
            Check(tests,@"tracked_state_snapshot",snapshotOK,@"Tracked wrapper state captured before modifications");
            if (!snapshotOK) break;
            // GL4ES emulates desktop VAO state. Isolate the underlying ES3 VAO
            // without asking its unsupported VAO-binding getter for an ID.
            glGenVertexArrays(1,&isolatedNativeVAO); glBindVertexArray(isolatedNativeVAO);
            const GLsizei width=128,height=96;
            a.glGenTextures(1,&texture); a.glBindTexture(GL_TEXTURE_2D,texture);
            a.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST); a.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
            a.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE); a.glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
            a.glPixelStorei(GL_UNPACK_ALIGNMENT,1);
            a.glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
            a.glGenFramebuffers(1,&fbo); a.glBindFramebuffer(GL_FRAMEBUFFER,fbo);
            a.glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
            GLenum fboStatus=a.glCheckFramebufferStatus(GL_FRAMEBUFFER); NSArray *fboErrors=DrainErrors(a.glGetError);
            report[@"wrapper_framebuffer_status"]=@(fboStatus); report[@"wrapper_framebuffer_errors"]=fboErrors;
            Check(tests,@"wrapper_owned_rgba_texture_framebuffer",texture && fbo && fboStatus==GL_FRAMEBUFFER_COMPLETE && fboErrors.count==0,@"Texture and FBO allocated/attached through wrapped desktop APIs only");
            if (!texture || !fbo || fboStatus!=GL_FRAMEBUFFER_COMPLETE || fboErrors.count) break;
            vs=Compile(&a,GL_VERTEX_SHADER,"#version 120\nattribute vec2 position;\nvoid main(){gl_Position=vec4(position,0.0,1.0);}\n",shaderLogs);
            fs=Compile(&a,GL_FRAGMENT_SHADER,"#version 120\nvoid main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}\n",shaderLogs);
            report[@"shader_logs"]=shaderLogs;
            if (vs && fs) {
                program=a.glCreateProgram(); a.glAttachShader(program,vs); a.glAttachShader(program,fs);
                a.glBindAttribLocation(program,0,"position"); a.glLinkProgram(program);
            }
            GLint linked=0; if (program) a.glGetProgramiv(program,GL_LINK_STATUS,&linked);
            report[@"program_link_log"]=program ? ShaderLog(&a,program,YES) : @"No program created";
            Check(tests,@"glsl120_translation_compile_link",vs && fs && linked,@"Original diagnostic #version120 shaders compiled and linked through GL4ES");
            if (!vs || !fs || !linked) break;
            const GLfloat vertices[]={-0.75f,-0.75f, 0.75f,-0.75f, 0.0f,0.75f};
            a.glGenBuffers(1,&buffer); a.glBindBuffer(GL_ARRAY_BUFFER,buffer); a.glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices,GL_STATIC_DRAW);
            a.glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,NULL); a.glEnableVertexAttribArray(0);
            a.glViewport(0,0,width,height); for (int i=0;i<6;i++) a.glDisable(caps[i]);
            a.glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE); a.glClearColor(0,0,1,1); a.glClear(GL_COLOR_BUFFER_BIT);
            a.glUseProgram(program); a.glDrawArrays(GL_TRIANGLES,0,3); a.glFinish();
            a.glPixelStorei(GL_PACK_ALIGNMENT,1);
            GLubyte center[4]={0},background[4]={0};
            a.glReadPixels(width/2,height/2,1,1,GL_RGBA,GL_UNSIGNED_BYTE,center); a.glReadPixels(2,2,1,1,GL_RGBA,GL_UNSIGNED_BYTE,background);
            NSArray *drawErrors=DrainErrors(a.glGetError);
            report[@"wrapper_render_errors"]=drawErrors;
            report[@"wrapper_pixels"]=@{@"size":@[@(width),@(height)],@"center":Pixel(center),@"background":Pixel(background),@"expected_center":@[@255,@0,@0,@255],@"expected_background":@[@0,@0,@255,@255],@"tolerance_per_channel":@2};
            BOOL sourcePixels=Matches(center,255,0,0) && Matches(background,0,0,255) && drawErrors.count==0;
            Check(tests,@"wrapper_shader_draw_readback",sourcePixels,@"Wrapper readback must show red triangle center and blue clear background");
            if (!sourcePixels) break;
            GLint nativeSource=0,wrapperBound=0;
            a.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&wrapperBound); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&nativeSource);
            GLenum sourceStatus=glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
            report[@"framebuffer_mapping"]=@{@"wrapper_fbo":@(fbo),@"wrapper_bound_fbo":@(wrapperBound),@"observed_native_draw_fbo":@(nativeSource),@"native_status":@(sourceStatus),@"destination_native_fbo":@(surface.framebuffer)};
            BOOL mappingOK=wrapperBound==(GLint)fbo && nativeSource>0 && sourceStatus==GL_FRAMEBUFFER_COMPLETE && nativeSource!=(GLint)surface.framebuffer;
            Check(tests,@"observed_native_source_framebuffer",mappingOK,@"Native FBO observed after wrapper flush/readback; no assumption about wrapper/native name equivalence");
            if (!mappingOK) break;
            report[@"native_errors_before_bridge"]=DrainErrors(glGetError);
            glBindFramebuffer(GL_READ_FRAMEBUFFER,(GLuint)nativeSource); glReadBuffer(GL_COLOR_ATTACHMENT0);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER,surface.framebuffer); glDisable(GL_SCISSOR_TEST);
            GLenum destinationStatus=glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
            report[@"native_destination_framebuffer_status"]=@(destinationStatus);
            if (destinationStatus!=GL_FRAMEBUFFER_COMPLETE) { Check(tests,@"native_destination_complete",NO,@"Host drawable framebuffer incomplete"); break; }
            glBlitFramebuffer(0,0,width,height,0,0,surface.drawableWidth,surface.drawableHeight,GL_COLOR_BUFFER_BIT,GL_NEAREST);
            glFinish(); glBindFramebuffer(GL_READ_FRAMEBUFFER,surface.framebuffer); glReadBuffer(GL_COLOR_ATTACHMENT0); glPixelStorei(GL_PACK_ALIGNMENT,1);
            GLubyte presentedCenter[4]={0},presentedBackground[4]={0};
            glReadPixels(surface.drawableWidth/2,surface.drawableHeight/2,1,1,GL_RGBA,GL_UNSIGNED_BYTE,presentedCenter);
            glReadPixels(2,2,1,1,GL_RGBA,GL_UNSIGNED_BYTE,presentedBackground);
            NSArray *bridgeErrors=DrainErrors(glGetError);
            report[@"native_bridge_errors"]=bridgeErrors; report[@"destination_pixels"]=@{@"center":Pixel(presentedCenter),@"background":Pixel(presentedBackground),@"size":@[@(surface.drawableWidth),@(surface.drawableHeight)]};
            BOOL copied=bridgeErrors.count==0 && Matches(presentedCenter,255,0,0) && Matches(presentedBackground,0,0,255);
            Check(tests,@"native_blit_destination_pixels",copied,@"Actual host drawable readback matches the wrapped offscreen triangle");
            if (!copied) break;
            NSError *presentError=nil; BOOL presented=[surface presentDrawable:&presentError];
            Check(tests,@"eagl_present_wrapped_triangle",presented,presentError.localizedDescription ?: @"Host EAGL presented the copied color renderbuffer");
        } while (0);
    } @catch (NSException *exception) {
        Check(tests,@"unexpected_exception",NO,[NSString stringWithFormat:@"%@: %@",exception.name,exception.reason]);
    } @finally {
        if (snapshotOK) {
            // Return from the native bridge before wrapper cleanup/state work.
            a.glBindFramebuffer(GL_FRAMEBUFFER,fbo ?: (GLuint)oldFBO);
            a.glUseProgram((GLuint)oldProgram);
            a.glBindBuffer(GL_ARRAY_BUFFER,(GLuint)attribBuffer);
            a.glVertexAttribPointer(0,attribSize,(GLenum)attribType,(GLboolean)attribNormalized,attribStride,attribPointer);
            if (attribEnabled) a.glEnableVertexAttribArray(0); else a.glDisableVertexAttribArray(0);
            a.glBindBuffer(GL_ARRAY_BUFFER,(GLuint)oldBuffer);
            a.glActiveTexture(GL_TEXTURE0); a.glBindTexture(GL_TEXTURE_2D,(GLuint)oldTexture0); a.glActiveTexture((GLenum)oldActive);
            a.glPixelStorei(GL_PACK_ALIGNMENT,oldPack); a.glPixelStorei(GL_UNPACK_ALIGNMENT,oldUnpack);
            a.glViewport(oldViewport[0],oldViewport[1],oldViewport[2],oldViewport[3]);
            a.glColorMask(oldMask[0],oldMask[1],oldMask[2],oldMask[3]); a.glClearColor(oldClear[0],oldClear[1],oldClear[2],oldClear[3]);
            for (int i=0;i<6;i++) { if (oldCaps[i]) a.glEnable(caps[i]); else a.glDisable(caps[i]); }
            if (program) a.glDeleteProgram(program); if (vs) a.glDeleteShader(vs); if (fs) a.glDeleteShader(fs);
            if (buffer) a.glDeleteBuffers(1,&buffer); if (fbo) a.glDeleteFramebuffers(1,&fbo); if (texture) a.glDeleteTextures(1,&texture);
            a.glBindFramebuffer(GL_FRAMEBUFFER,(GLuint)oldFBO);
            if (oldReadFBO!=oldFBO) a.glBindFramebuffer(GL_READ_FRAMEBUFFER,(GLuint)oldReadFBO);
            a.glFinish();
            NSArray *cleanupErrors=DrainErrors(a.glGetError); report[@"wrapper_cleanup_errors"]=cleanupErrors;
            GLint restoredFBO=0,restoredProgram=0,restoredBuffer=0;
            a.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&restoredFBO); a.glGetIntegerv(GL_CURRENT_PROGRAM,&restoredProgram); a.glGetIntegerv(GL_ARRAY_BUFFER_BINDING,&restoredBuffer);
            Check(tests,@"wrapper_tracked_state_restored",cleanupErrors.count==0 && restoredFBO==oldFBO && restoredProgram==oldProgram && restoredBuffer==oldBuffer,@"Owned wrapper resources deleted; tracked framebuffer/program/buffer and render state restored");
        } else {
            a.glActiveTexture((GLenum)oldActive);
        }
        glBindVertexArray((GLuint)nativeVAO); if (isolatedNativeVAO) glDeleteVertexArrays(1,&isolatedNativeVAO);
        glUseProgram((GLuint)nativeProgram); glBindBuffer(GL_ARRAY_BUFFER,(GLuint)nativeArrayBuffer);
        glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D,(GLuint)nativeTexture0); glActiveTexture((GLenum)nativeActive);
        glBindFramebuffer(GL_READ_FRAMEBUFFER,(GLuint)nativeRead); glReadBuffer((GLenum)nativeReadBuffer); glBindFramebuffer(GL_DRAW_FRAMEBUFFER,(GLuint)nativeDraw);
        glBindRenderbuffer(GL_RENDERBUFFER,(GLuint)nativeRBO); glPixelStorei(GL_PACK_ALIGNMENT,nativePack); glPixelStorei(GL_UNPACK_ALIGNMENT,nativeUnpack);
        glViewport(nativeViewport[0],nativeViewport[1],nativeViewport[2],nativeViewport[3]);
        glColorMask(nativeMask[0],nativeMask[1],nativeMask[2],nativeMask[3]); glClearColor(nativeClear[0],nativeClear[1],nativeClear[2],nativeClear[3]);
        for (int i=0;i<6;i++) { if (nativeCaps[i]) glEnable(caps[i]); else glDisable(caps[i]); }
        NSArray *nativeRestoreErrors=DrainErrors(glGetError); report[@"native_restore_errors"]=nativeRestoreErrors;
        GLint restoredRead=0,restoredDraw=0,restoredRBO=0; glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&restoredRead); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&restoredDraw); glGetIntegerv(GL_RENDERBUFFER_BINDING,&restoredRBO);
        Check(tests,@"native_presentation_state_restored",nativeRestoreErrors.count==0 && restoredRead==nativeRead && restoredDraw==nativeDraw && restoredRBO==nativeRBO && EAGLContext.currentContext==surface.context,@"Host FBO/renderbuffer bindings and raw render state restored; current EAGL context preserved");
    }
    NSUInteger passed=0; for (NSDictionary *test in tests) if ([test[@"status"] isEqual:@"pass"]) passed++;
    report[@"tests"]=tests; report[@"passed"]=@(passed); report[@"failed"]=@(tests.count-passed); report[@"status"]=passed==tests.count ? @"pass" : @"fail";
    return report;
}
