# GPULife

GPULife is a macOS screen saver that runs Conway's Game of Life on the GPU using
OpenGL.

## Requirements

- macOS
- Xcode with command line tools installed

If `xcodebuild` reports first-launch setup errors, run:

```sh
xcodebuild -runFirstLaunch
```

## Build

From the repository root:

```sh
xcodebuild -project GPULife/GPULife.xcodeproj -scheme "GPULife saver" -configuration Deployment clean build
```

Or from this `GPULife` directory:

```sh
xcodebuild -project GPULife.xcodeproj -scheme "GPULife saver" -configuration Deployment clean build
```

The build creates a screen saver bundle in Xcode DerivedData and also copies it
to:

```text
~/Library/Screen Savers/GPULife.saver
```

The copied bundle is ad-hoc signed by Xcode for local use.

## Run

1. Open System Settings.
2. Go to Screen Saver.
3. Select GPULife.
4. Use Preview or wait for the screen saver to start.

If System Settings was already open during the build, quit and reopen it so it
reloads the installed screen saver bundle.

In Apple's legacy screensaver host, GPULife tracks the ScreenSaverEngine or System
Settings process presenting each animation. When that process exits, GPULife
stops its animation timer and releases its renderer, even if the host omits
`stopAnimation`. A later explicit start can render again. If no presenting
application can be identified, the usual screensaver lifecycle remains in effect.

On macOS 26 and later, Settings previews also track the preview dialog and its
parent using WindowServer metadata. Clicking Done releases the renderer without
requiring System Settings to quit. A twice-per-second visibility check allows
the same view to resume when Settings reopens the dialog without calling
`startAnimation`. Hiding Settings also pauses rendering until its windows return.
If Settings creates a new preview instance, it retires the previous one. This
does not depend on window titles, screen recording access, or the legacy host's
unreliable occlusion state. Window metadata is checked at most twice per second
while a Settings preview is active; fullscreen sessions do not use this check.
The configuration host announces a new GPULife preview through a notification
scoped to the Settings process, so a reused renderer can follow a replacement
dialog window without guessing from unrelated Settings windows.

## Verify

Check that the installed bundle is present, signed, and built for x86_64:

```sh
codesign --verify --deep --strict --verbose=2 ~/Library/"Screen Savers"/GPULife.saver
file ~/Library/"Screen Savers"/GPULife.saver/Contents/MacOS/GPULife
```

The screen saver currently builds as an x86_64 bundle because modern macOS loads
legacy screen savers through the x86_64 legacy screen saver host.

Run the visibility/lifecycle regression test against the installed bundle:

```sh
xcrun clang -arch x86_64 -framework Cocoa -framework ScreenSaver \
  GPULife/tests/PreviewLifecycle.m -o /tmp/gpulife-preview-lifecycle
/tmp/gpulife-preview-lifecycle "$HOME/Library/Screen Savers/GPULife.saver"
```

The test replaces the OpenGL child with a frame counter and verifies continued
rendering after two seconds of reported window occlusion, along with cleanup on
stop, hiding, and detachment. It exercises both preview and fullscreen modes.
It also checks presenting-application exit, a missed exit notification, unrelated
and stale exit notifications, and restarting with a new presenting application.
Settings-specific cases cover delayed dialog creation, Done while Settings stays
open, hide/resume, unavailable window metadata, and replacement of an old preview
when the dialog's window ID is reused, including reopening without a start callback.

Run the OpenGL rendering regression test:

```sh
xcrun clang -arch x86_64 -Wno-deprecated-declarations \
  -framework Cocoa -framework OpenGL \
  GPULife/tests/Rendering.m -o /tmp/gpulife-rendering
/tmp/gpulife-rendering "$HOME/Library/Screen Savers/GPULife.saver"
```

This briefly opens small windows, checks the viewport against the view's backing
dimensions, and reads pixels at the actual top and right edges. Initial and
resized frames are checked separately. It also verifies that removing
a view preserves another view's OpenGL viewport. Simulation stepping is disabled
to keep the pixels deterministic; this does not reproduce external-display host
timing issues.

## Gatekeeper

This project is not notarized for distribution. A local Xcode build should be
ad-hoc signed and installed under `~/Library/Screen Savers`, which is suitable
for local testing. If macOS blocks a downloaded copy, prefer rebuilding locally
from source.
