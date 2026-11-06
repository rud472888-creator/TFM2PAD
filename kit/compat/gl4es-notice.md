# GL4ES dependency and integration notice

This toolkit builds [official GL4ES](https://github.com/ptitSeb/gl4es) at commit `bc4314d8369f169d3fa81c5ed1b46b3dba4e74a5`, reporting upstream version **1.1.7**. GL4ES translates a subset of desktop OpenGL to OpenGL ES. Its normal GLES2 backend exposes an OpenGL **2.1 / GLSL 1.20** emulation target. This is not desktop OpenGL 4.1, and compilation does not establish that the original game's Skia renderer works.

The pinned source's [iOS build instructions](https://github.com/ptitSeb/gl4es/blob/bc4314d8369f169d3fa81c5ed1b46b3dba4e74a5/COMPILE.md) document external context creation, `NOX11`, `NOEGL`, static builds, and initialization after making an EAGL context current. This build uses the installed iPhoneOS 27.1 SDK, ARM64, and a minimum iOS version of 15. It installs nothing system-wide. No game shaders, game files, Steam binary, or account data are incorporated into this dependency.

Reproduce after fetching the official source and checking out the pinned commit:

```sh
python3 tools/build_gl4es.py --source /path/to/gl4es --output /fresh/build-directory
```

The script refuses a different commit or tracked source modifications. It emits `lib/libGL.a`, `TFMGL4ES.dylib`, an export/dependency-checked build report, logs, the upstream initialization header, and its license. Upstream source files are unchanged. The local build adds forwarding definitions for exactly two `void(array,index)` aliases because Darwin clang rejects their upstream ELF alias attributes. It also sets target-final default visibility so real wrapper and initialization functions can be dynamically resolved. The callback aliases described below are separate small host integration functions. This build integration was authored with Codex; no upstream contribution or pull request is made.

## Host integration contract

1. Create an actual EAGL context and drawable and make that context current on the host's main thread. GL4ES does not create an iOS window, EAGL context, or presentation surface.
2. Open the **real** system `OpenGLES.framework/OpenGLES` with a library-local lookup scope. Supply a driver callback that resolves GLES entrypoints from that handle. It must never resolve back through GL4ES or the process-wide namespace, which would recurse.
3. Call `set_getprocaddress(driverCallback)` or its exported alias `gl4es_set_getprocaddress(driverCallback)`. The callback signature is `void *callback(const char *name)`.
4. Call `set_getmainfbsize(sizeCallback)` or `gl4es_set_getmainfbsize(sizeCallback)`. The signature is `void callback(int *width, int *height)`; provide the real backing dimensions.
5. Call `initialize_gl4es()` once, while that actual EAGL context is current, before wrapper GL use. Keep the default GLES2 backend and desktop 2.1 target; do not use version overrides to advertise a higher API.
6. Pass `gl4es_GetProcAddress(name)` as the desktop function resolver to the original Skia entrypoint. Its GL strings describe the wrapper target, so record the underlying real GLES strings separately. Do not use raw GLES functions as a fallback for an unknown desktop function with different semantics.
7. Keep the wrapper's context/state lifecycle separate from unrelated raw GLES rendering. Call `close_gl4es()` only after wrapper consumers are released and while its context is current. This pinned build's close path does not reset the one-time initialization guard; do not assume it supports close/reinitialize cycles in one process.

The generated dylib exports `initialize_gl4es`, `close_gl4es`, `set_getprocaddress`, `set_getmainfbsize`, `gl4es_GetProcAddress`, and the two explicit `gl4es_set_*` callback aliases. Its 981 `gl4es_gl*` exports are implementation symbols, not proof that all operations are implemented. On Apple it does not define unprefixed `glGetString`; native GLES calls remain distinct from wrapper calls.

## Rendering boundaries and known limitations

GL4ES tracks framebuffer names that it creates. An arbitrary framebuffer created directly by EAGL/GLES is not registered with that state: passing the host surface's raw framebuffer number to GL4ES `glBindFramebuffer` fails its lookup. The native iOS drawable also is not necessarily framebuffer zero. A real bridge must explicitly integrate external framebuffer ownership or render into wrapper-created offscreen resources and present through a defined native boundary. The size callback alone does not register the drawable.

In this pinned source, `glDrawBuffer` and `glReadBuffer` are logging stubs; `glBindFragDataLocation` is absent. `glPolygonMode` and `glMapBuffer` have implementations, but their correctness for this game's calls remains unverified. A non-null function pointer is not evidence of successful rendering. Unknown resolver names return null.

Upstream documents incomplete shader conversion, missing depth/stencil readback, multiple color attachment limits, and texture/other API restrictions. This library cannot be used as proof of complete OpenGL 2.1 behavior, GLSL 4.00 support, desktop 4.1 compatibility, or a runnable game. Validate the original Skia context, actual generated shaders, color output, framebuffer ownership, and presentation on the target iPad before making those claims.

## Upstream license

Copyright (c) 2016-2018 Sebastien Chevalier
Copyright (c) 2013-2016 Ryan Hileman

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
