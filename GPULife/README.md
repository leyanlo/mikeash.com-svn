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

## Verify

Check that the installed bundle is present, signed, and built for x86_64:

```sh
codesign --verify --deep --strict --verbose=2 ~/Library/"Screen Savers"/GPULife.saver
file ~/Library/"Screen Savers"/GPULife.saver/Contents/MacOS/GPULife
```

The screen saver currently builds as an x86_64 bundle because modern macOS loads
legacy screen savers through the x86_64 legacy screen saver host.

## Gatekeeper

This project is not notarized for distribution. A local Xcode build should be
ad-hoc signed and installed under `~/Library/Screen Savers`, which is suitable
for local testing. If macOS blocks a downloaded copy, prefer rebuilding locally
from source.
