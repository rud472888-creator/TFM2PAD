# Display compatibility adapter notice

`DisplayCompat.m` adapts the UIKit screen geometry and retained dictionary mode pattern from AgePad `port/de/DisplayModeCompat.m`, by Chris Sotraidis. This adapter adds process-lifetime identifiers, native pixel sizes, safe opaque-mode lookup, explicit invalid-input handling, and independent smoke tests. It does not implement display capture, fading, mode switching, or a runnable game.

The adapter is main-thread-only. Bounds describe each UIKit screen's coordinate space, without a macOS desktop arrangement. Mode enumeration contains only the current UIKit surface. Native pixel dimensions come from `UIScreen.nativeBounds`; refresh rate is 0 (unknown), while UIKit's maximum frame capability is recorded separately. It makes no claim that this is sufficient to run the game or provide its renderer.

AgePad license:

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
