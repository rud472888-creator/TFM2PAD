# Steam client runtime boundary notice

These sources are a separate, device-survey-driven foundation for a future diagnostic `dlopen` of the user's genuine ARM64 Steam client. They do not implement Steam authentication, licensing, ownership, or a substitute client. Building them does not load the client or establish that its constructors complete.

`tools/build_steam_boundaries.py` uses the completed actual-iPad symbol survey, the hash-pinned isolated client stage, and an explicitly supplied existing game-boundary build. It verifies every requested missing export as a direct definition or an actual reexport and emits maps for a later metadata-only rewrite of private copies. `dyld_stub_binder` is a loader special symbol and is excluded. Do not apply these maps to the installed Steam files.

The current survey requires 39 API/data names. Ten new dylibs provide 31 direct names and eight inherited names. Seventeen unknown functions terminate through the shared boundary diagnostic (`Documents/boundary-failure.json`, exit 78). All other imported system functions continue through genuine iOS framework/libSystem reexports. Presence-observer code must remain loaded for the process lifetime.

## Scoped behavior

- `TFMSteamAppKit` defines only `NSWorkspace`, `NSRunningApplication`, a private base class, and the two measured workspace configuration strings. It reexports the supplied `TFMAppKit` for `NSScreen`; it does not redefine that class or `NSApplication`.
- A running-application object represents this actual host process. It reports the real PID, bundle identity and URLs. Queries for this process can return that object. Global `runningApplications` returns **nil because enumeration is unavailable**, never a purported empty or complete one-element system application list. Other-process and other-bundle queries similarly return nil as unavailable. `frontmostApplication` returns this host only while its own UIKit application is observed active; otherwise the global foreground application remains unknown. Unsupported cross-process launch returns nil with an unsupported-operation error.
- `ApplicationServices` supports the app's current-process sentinel and maps it to the real host PID. Its front-process answer is restricted to this app being observed active; it does not enumerate or name another foreground app. Invalid arguments and other process tokens return errors.
- `CoreGraphics` inherits the existing scene-aware display adapter. The one added any-input idle query follows AgePad's **app-presence policy**: this app being foreground counts as use, and time after resigning active comes from real process uptime. This is not actual global input idle or per-key/per-button timing. Other event-type requests and unobserved activity fail fast. Physical display dimensions/bit-depth queries and unimplemented event creation, posting and state APIs also fail fast.
- `DiskArbitration` returns NULL for its absent macOS service. The media UUID key is the measured public string `DAMediaUUID`; no disk or machine UUID is invented. Prior upstream callers handled unavailable service; the current client still needs its own runtime test.
- `IOBluetoothDevice` provides class metadata; paired-device and address queries return nil as service unavailable. This is not a claim that the device has no Bluetooth hardware or no paired devices. Unsupported selectors fail fast.
- `syslog$DARWIN_EXTSN` has the genuine variadic logging signature and forwards to iOS `vsyslog` with its `va_list`.
- Missing CoreServices filesystem/Apple Event/Launch Services functions fail fast. Carbon has no direct imports in this client set. Cocoa reexports the client AppKit boundary and genuine Foundation; OpenGL reexports the existing game graphics boundary. These imports do not constitute a general macOS desktop environment.

Public string values in `constants.json` were measured using AgePad's `HostConstants.m`, loading only the Mac's AppKit and DiskArbitration system frameworks. No Steam code, account data, session state, configuration or token was accessed by that measurement.

## Upstream reuse and license

`AppPresence.h`, `ApplicationServices.m`, `CoreGraphics.m`, and `DiskArbitration.m` selectively adapt the app-presence/process-manager/unavailable-service principles from AgePad `port/steam-engine/{AppPresence.h,ApplicationServicesClient.m,CoreGraphicsClient.m,DiskArbitrationUnavailable.m}`. Upstream repository: https://github.com/chrissotraidis/agepad, commit `c0f7cbdc69d8b1dca87a73a94490c3a65405762f`. The other implementation and builder code is original toolkit integration. Valve's client binaries are not included in these source deliverables.

MIT License

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

This license covers AgePad's own code and documentation only. Age of Empires II:
Definitive Edition, Steam and their files belong to their owners and are not
included in or licensed by this repository.
Third-party code and patches listed in THIRD_PARTY_NOTICES.md keep their own licenses.
