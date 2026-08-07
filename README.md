# DockCraft

A macOS utility for customizing your Dock, including secondary, independently configurable Dock-like panels alongside the system Dock.

## Requirements

- macOS 14.0 or later

## Installation

1. Download the latest `DockCraft-x.y.zip` from [Releases](../../releases), unzip it, and drag `DockCraft.app` to `/Applications`.
2. **First launch:** this build is signed but not notarized (that requires a paid Apple Developer Program membership). macOS will refuse to open it with a normal double-click the first time. Right-click `DockCraft.app` → **Open** → **Open** in the confirmation dialog. You only need to do this once per version. (Or: **System Settings → Privacy & Security**, scroll down, click **Open Anyway**.)
3. Choose how DockCraft appears — Dock icon, menu bar item, or both — from its main window.

## Building from source

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open DockCraft.xcodeproj
```

## License

MIT — see [LICENSE](LICENSE).
