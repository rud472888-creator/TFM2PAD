# Original game graphics integration

`TFMOpenGL.m`, `TFMCoreFoundation.m`, and `ColorSyncCompat.m` are narrow adapters
authored for this personal port. They contain no original game instructions,
assets, account information, or Steam authentication replacement.

The context interface follows the selectors used by
[glutin 0.32.1](https://github.com/rust-windowing/glutin/tree/v0.32.1/glutin/src/api/cgl).
Core 4.1 and 3.2 pixel formats are rejected. glutin's own legacy fallback selects
the GL4ES desktop 2.1 target, whose actual version string remains visible. An
EAGL ES3 context and real UIKit drawable provide storage and presentation.
Unknown or unsupported operations fail explicitly; no desktop 4.1 support is
advertised. Shared contexts and multisampled drawables are not implemented.

Only one retained native/wrapper context is supported per process. The default
desktop framebuffer zero maps to the actual nonzero EAGL drawable framebuffer
at the driver boundary. Renderbuffer zero keeps its ordinary unbound meaning.
Swap interval one uses EAGL's minimum presentation duration based on the screen's
maximum cadence; exact desktop retrace timing is not established.

The CoreFoundation adapter reexports the real iOS framework and overrides only
the two bundle lookup functions needed for the OpenGL framework lookup. It
returns a real, separately staged CFBundle for the adapter and resolves functions
through GL4ES while its context is current. Other bundle lookups use the actual
CoreFoundation implementation. Logical display UUIDs are real CFUUID objects
created for connected display IDs, cached for this process, and returned with
Create ownership. They are not hardware identifiers or persistent screen IDs.

Independent original-Skia context creation and GL4ES shader/pixel/presentation
probes passed on the target iPad. Those probes do not validate this NSOpenGL
integration or original game rendering by themselves. Startup observations and
remaining failures are recorded separately in `evidence/`.

GL4ES licensing and known limitations are in `gl4es-notice.md`. AgePad-derived
AppKit and display code is attributed in `TFMAppKit-NOTICE.md` and `NOTICE.md`.
