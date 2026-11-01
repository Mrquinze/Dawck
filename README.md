# Dawck

A macOS dock utility. Dawck tunes the system Dock, and adds any number of its
own floating docks — each on its own display and edge, each rendered in a
customizable Liquid Glass theme.

**New in 3.0** — a rewritten dock renderer (hovering, magnifying, appearing and
glowing hold 60 fps at a fraction of the CPU), no more rectangular layer around
docks, native Apple Liquid Glass and a palette editor with Goorgle's palettes,
thirteen new widgets, docks that hide for full-screen apps and covering windows,
edit mode and locking, smarter drops, better folders, a glass settings window,
a welcome tour, automatic backups, and safer profile imports. The welcome window
(Settings → General → *Show What's New*) lists everything.

Formerly DockCraft.

## What it does

**Custom docks.** Add as many floating tile bars as you like. Pin each one to a
display and an edge, slide it anywhere along that edge, and size its tiles
independently. Display pinning uses the monitor's hardware UUID, so a dock
returns to the right screen after the monitor is unplugged and plugged back in.

**Kinds of tile.**

| Tile | What it is |
| --- | --- |
| App or folder | Launches (with a bounce), or opens a folder as a grid, list or fan with previews. Clicking a running app sends it the same "reopen" the real Dock does, so an app with no windows gets one. Calendar and Clock tiles show the live date and time. Drop files onto an app to open them with it, onto a folder to move them in (⌥ copies). |
| Action | A deep link (`spotify:`, `slack://`, `raycast://`, `things:///`, `https://`), an Apple Shortcut, a shell command, or an AppleScript. |
| Widget | Twenty-two live readouts and controls — see below. |
| Trash | Opens the Trash, shows whether it's full, throws away files dropped on it, empties it. |
| Spacer | A gap. |
| Group | Several apps folded behind one tile, drawn as their icons in quadrants, fanning out on click. |
| Tray | A staging shelf. Drag files in to park them, drag them back out later. Contents survive relaunch. |

**Widgets.** Clock, analogue clock, world clock, date, month calendar (click for
the whole month), CPU, memory, GPU, battery, disk, network speed, IP address
(click to copy), device batteries, thermal state, stopwatch, countdown timer,
audio output, now playing (Music and Spotify), volume (scroll to change it),
keyboard layout (click to switch), keep-awake, and weather. Every widget measures
only while it is on a dock that is showing, and waits on a system notification
where one exists instead of polling. The three that use the internet — public IP,
weather — say so, and do nothing until placed on a dock.

**Behaviour.** A dock can be locked so nothing moves by accident (right-click →
*Edit Dock* to change it, with minus badges like the real Dock); can hide while
an app is full screen or a window covers it, and come back when the pointer
reaches the screen edge (narrow, standard or wide); can appear on every display;
can sit behind windows like a widget; has its own global show/hide shortcut;
and fades, slides or pops in and out.

**Content modes.** A dock can show your own tiles, filter them down to apps that
are *running*, filter them to apps with a window on the Space you're looking at,
or mirror your real Dock wholesale onto another display.

**Collapsing.** A dock can shrink to a small button and expand on hover or on
click, or hide completely and reappear when you push the pointer into the screen
edge.

**Menu Mode.** Every dock and every action is also listed under Dawck's single
menu bar icon, so you can run all of it without a floating panel on screen.

**Menu bar clusters.** Named groups of menu bar icons you can fold away
individually, rather than one blanket "hidden" pile. Each cluster gets its own
handle in the menu bar, its own glyph, its own re-fold delay, and its own
toggle. Command-drag your icons so the ones you want in a cluster sit to the
left of its handle, then click the handle to fold them away.

Clusters nest from the right: folding one also folds anything further left.
That isn't a design choice — macOS lays the menu bar out right to left, and the
only permission-free way to hide an icon is to widen an item until what's left
of it goes off-screen. Reaching icons in arbitrary order would mean driving the
Accessibility API, which is the permission this app is built to do without. Put
the group you fold most often furthest right.

**Inline actions.** A dock can also place its app and action tiles directly in
the menu bar as individual icons, instead of nesting them under Dawck's single
icon — ExtraBar's Inline mode. Capped at 12 placed items, so a large dock can't
evict every other app's icon.

**Themes.** A layered glass renderer with a live preview: substrate material,
tint and a second blended tint, translucency, a specular highlight that tracks
your pointer, edge lensing, rim light, depth falloff, frosted grain, corner
radius and curvature, and shadow.

The colour knobs go further than glass: tint the rim and edge light so the panel
looks lit by neon rather than daylight, add an outer glow in its own colour,
colour the shadow, set icon saturation from greyscale to oversaturated, choose
the tile backing shape (squircle, rounded, circle, capsule, or none), and set a
hue drift so the tint travels slowly around the colour wheel. Per dock: the
running indicator's style (dot, bar, ring, glow) and colour, what hovering does
(magnify, lift, tilt, glow, nothing), greying out apps that aren't running, and
whether the dock floats as a pill or stretches edge to edge like a taskbar.

A theme is a *design* (the shape and feel) plus a *palette* (up to five colours
and an angle), kept apart so any design can wear any palette. There are three
fills: Dawck's own layered glass, a gradient painted straight onto the plate
(Goorgle's look, with its twenty palettes), and Apple's native Liquid Glass on
macOS 26 and later, clear or frosted. On macOS 27 a theme can follow the
system-wide clear↔opaque Liquid Glass slider. Themes export and import as JSON,
and a dock can use its own theme instead of the active one.

**Profiles.** A named snapshot of the whole setup — system Dock settings, every
custom dock, and the theme. Switch between them in one click from the window or
the menu bar. Profiles export as plain JSON.

**System Dock settings.** Icon size, magnification, position and edge pinning,
minimize effect, auto-hide and its timings, recent apps, process indicators,
single-app mode, icon bouncing, dimming hidden apps, grouping windows by app in
Mission Control, Space rearranging, scroll-to-open, spring-loading, and the app
switcher across displays. Plus three lock switches — size, position, and
contents — to freeze the Dock as it is.

**Dock contents.** Edit the real Dock directly: reorder tiles by dragging, add
or remove apps and folders, insert spacers, choose how each folder presents
itself (fan, grid, list; folder or stack), and sweep out tiles whose target has
gone missing — the ones the Dock shows as blank question marks and gives you no
way to find.

**Hot corners.** All four corners, every action, with an optional modifier so a
corner can't fire by accident.

**Backups.** Docks, themes and profiles are snapshotted automatically once a day
when something has changed (ten kept), or on demand, and restored from Settings
→ General. A restore backs up the current state first.

**AppSense.** Switch profiles automatically when an app comes forward — focus
Xcode and your dev layout appears, focus Mail and it doesn't. Costs no
permission: macOS tells any app which app is frontmost.

## Permissions and safety

Dawck asks for no permission up front. Window-aware features read only window
frames, owners and layers, never contents or titles, so macOS never prompts for
Screen Recording or Accessibility. Global shortcuts use the Carbon hot-key API,
which needs neither Accessibility nor Input Monitoring. Tiles that control
another app (Play/Pause for Music, emptying the Trash, AppleScript and Shortcut
actions) send Apple Events only when clicked, and macOS asks then; Dawck declares
the single `apple-events` entitlement for that under the Hardened Runtime.

Anything arriving in a shared profile is treated as untrusted: files are
size-limited, every number is clamped, collections are capped, app tiles lose
custom names and icons (so one app can't pose as another), and **every action
tile is switched off until you have read and approved it**. The widgets that use
the network (public IP, weather) contact only `api.ipify.org` and
`open-meteo.com` over HTTPS, and only when one is on a dock.

## Requirements

macOS 14.0 or later. Universal (Apple Silicon and Intel). Liquid Glass fills need
macOS 26+, and the system-slider following needs macOS 27; everything else works
from macOS 14. Developed and tested on macOS 27.

## Installation

1. Download the latest `Dawck-x.y.dmg` from [Releases](../../releases), open it,
   and drag `Dawck.app` to `Applications`.
2. **First launch:** this build is signed ad-hoc but not notarized (notarization
   requires a paid Apple Developer Program membership). macOS will refuse to open
   it with a normal double-click the first time. Right-click `Dawck.app` →
   **Open** → **Open** in the confirmation dialog. Once per version. (Or:
   **System Settings → Privacy & Security**, scroll down, **Open Anyway**.)
3. Choose how Dawck appears — Dock icon, menu bar item, or both — under General.

## Building from source

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open Dawck.xcodeproj
```

To run the unit tests:

```bash
xcodebuild -project Dawck.xcodeproj -scheme Dawck -destination 'platform=macOS' \
  PRODUCT_BUNDLE_IDENTIFIER=com.matanlevi.Dawck.dev CODE_SIGNING_ALLOWED=NO test
```

(Use the `.dev` bundle identifier for any local experiment: Dawck refuses to
write the real Dock's preferences or restart the Dock from any other identity,
so a test run can never disturb your own setup.)

To build a distributable disk image (universal, ad-hoc signed, with artwork and
a laid-out installer window):

```bash
./scripts/build-dmg.sh
```

The installer layout is written by [dmgbuild](https://github.com/dmgbuild/dmgbuild),
installed once into `.build-tools/` and pinned by SHA-256 in
`scripts/dmg-requirements.txt`; no Finder scripting or permission prompt is involved.

The app icon is generated rather than drawn by hand:

```bash
swift tools/makeicon.swift Dawck/Assets.xcassets/AppIcon.appiconset
```

## License

MIT — see [LICENSE](LICENSE).
