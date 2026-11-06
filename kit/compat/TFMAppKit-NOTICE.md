# TFMAppKit source and limits

TFMAppKit is a bounded startup bridge for the owned Teamfight Manager 2 Mac
program. It does not implement a complete AppKit, Steam client, GL renderer,
game loader, keyboard layout, or IME. It has no game-specific code addresses.

The UIKit-hosted window/view/frame/screen model and retained event queue are
selectively adapted from Chris Sotraidis's AgePad, commit
`c0f7cbdc69d8b1dca87a73a94490c3a65405762f`, principally
`port/de/WindowViewCompat.m`, `ScreenCompat.m`, `EventQueueCompat.m`,
`EventCompat.m`, and `MenuCompat.m`:
<https://github.com/chrissotraidis/agepad>.

AgePad's fixed-offset Feral launch routines, Steam sign-in, AoE controls,
legacy WebView code, and UIApplicationMain delegate replacement are excluded.
The winit bootstrap behavior was checked against upstream v0.30.5
`src/platform_impl/macos/{event_loop,app_state,window_delegate,view,menu}.rs`:
<https://github.com/rust-windowing/winit/tree/v0.30.5/src/platform_impl/macos>.
No Rust upstream source is embedded here.

Integration must set a real UIKit host window with `TFMAppKitSetHostWindow`
after its scene/root controller exist, then enter the original program on the
main thread. The library never creates a second UIApplication or calls
UIApplicationMain. `NSApplication run` drives a nested main CFRunLoop and
preserves the original winit application subclass and delegate. Launch callbacks
are delivered once. Unknown messages stop with a specific diagnostic.

`NSAppKitVersionNumber = 1504.0` is the adapter's limited 10.12 compatibility
feature gate, not an observation about iPadOS. Menus and tracking/drag rectangles
are retained object models; no native interaction is claimed for them. The
text context returns `TFMUIKitLocale:<locale identifier>` as an explicit locale
hint, not a macOS TIS keyboard-layout identifier. Only one host screen with
process-local display ID 1 is represented. No native game input is delivered.
Compilation alone is not runtime or gameplay evidence.

Runtime diagnostics atomically replace `Documents/appkit-progress.json` at host,
application, launch, run/stop and window milestones. They record class names,
window/run counts, booleans, process ID and timestamp only. Unknown selectors or
main-thread violations first write `Documents/appkit-failure.json`, flush stderr,
then call `_exit(78)` without running game destructors. A failed diagnostic write
is reported to stderr and does not suppress that exit. Records from a previous
process can remain; compare their process ID and timestamp with the current run.
Progress recording never creates an application singleton.

## AgePad MIT license

Copyright (c) 2026 Chris Sotraidis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
