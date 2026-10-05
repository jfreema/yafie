# Agents

Notes for any coding agent working on Yafie.

## What Yafie is

A macOS menu bar app with five features: stay awake with the lid closed, window snapping, app previews from the Dock, a screenshot tool and a guitar tuner. It's Swift 6 with SwiftPM, with no Xcode project and no third-party dependencies. It runs on macOS 14 or later, on Apple silicon or Intel. It's an accessory app (`LSUIElement`), with no Dock icon or menu bar except while a snip editor is open. [README.md](README.md) is the user guide.

## Build and test

```sh
swift build            # compile
swift test             # unit tests (Swift Testing)
./build.sh             # build/Yafie.app
./build.sh --install   # replace /Applications/Yafie.app and restart it
```

- **Command Line Tools only:** everything must build without Xcode. SwiftUI's `@State` doesn't build with them, since the macro plugin it needs isn't included. Keep SwiftUI state in `@Observable` models, as `TunerWindow` and `SnipEditor` do.
- **`swift test` sometimes fails with "plugin for module 'TestingMacros' not found".** It's a toolchain glitch, not the tests, so run it again. A real compile error can show up on a retry, so read the output each time.
- **Linker warnings about missing search paths** come from the Command Line Tools. Ignore them.
- **`./build.sh --install` quits and replaces the copy the user is running.** Ask first.
- **A debug build won't start while the installed Yafie is running.** The second copy hands over to the first and quits, so quit Yafie first. These hooks work in debug builds only: `--tuner`, `--snip-editor <image file>` and `--update-now`.
- **Logs:** `/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.jfreema.yafie"'`. The categories are `lid`, `snap`, `preview`, `snip` and `tuner`.

## Code

The app is one flat folder, `Sources/Yafie`, and the tests are in `Tests/YafieTests`.

| Area | Files |
|---|---|
| Menu, alerts, launch | `AppDelegate`, `Yafie` (entry point, one copy at a time), `ToggleRow`, `MenuSwitch` |
| Stay awake | `LidAwakeController`, `SleepSetting` (`pmset` through a sudoers rule), `PowerManager`, `PowerSource`, `Connectivity`, `Watchdog` (a second process that turns sleep back on if Yafie dies) |
| Window snapping | `WindowSnapper`, `SnapLayout` (pure geometry) |
| App preview | `AppPreview`, `DockWatcher` (the icon under the pointer), `AppWindows` (windows and their pictures), `PreviewPanel`, `PreviewLayout` (pure geometry) |
| Screenshot tool | `ScreenSnipper`, `SnipDrawing` (pure drawing and layout), `SnipEditor` |
| Guitar tuner | `TunerAudio`, `TunerWindow`, `PitchDetector` |
| Shared | `HotKeys` (every global shortcut), `Updater`, `Shell` |

Put logic that can be pure, like geometry, drawing and parsing, in pure types with unit tests. Tests use shell scripts as stand-ins for child processes, such as the tuner's listener and `screencapture`.

## Things that bite

- **The main thread runs lid sleep, so never block it.** Accessibility calls run on a queue with a timeout. Core Audio runs in a child process (`--tuner-listen`), because AVAudioEngine can hang for good after an audio device changes.
- **App Preview reads the Dock through Accessibility.** The Dock selects the icon under the pointer and posts `AXSelectedChildrenChanged` on its list, as DockDoor relies on too. Windows are matched to their pictures with the private `_AXUIElementGetWindow`, found with `dlsym`, since two windows can share a frame and title. Its panel is non-activating and must never take the focus.
- **Global shortcuts go through `HotKeys`**, which owns Yafie's one Carbon handler. A second handler would take other features' key presses.
- **⌘Q in the snip editor closes the editors, not Yafie.** While an editor is open, Yafie looks like a regular app, but quitting it would also stop Stay Awake and window snapping. **Quit Yafie** is in the menu, without the shortcut.
- **A menu item takes its key even when it's disabled.** So the snip editor's single-key shortcuts (R, L, A, H, T, 1 to 4, W) only exist while an editor has the keyboard and no text is being typed (`SnipMenu.setSingleKeys`). Otherwise those letters couldn't be typed in a text or a Save dialog's name.
- **Activation:** since macOS 14, `NSApp.activate()` is a request that macOS can turn down. Anything shown after a wait or from a pop-up menu must use `NSApp.activateRegardless()`. That includes alerts, the snip editor and Save dialogs. Otherwise it opens behind the app in front and Yafie looks stuck. Hand focus back with `NSApp.handFocus(back:)`.
- **The tuner must never open a Bluetooth microphone, or play any sound.** Opening a headset's microphone switches it to call mode, which can make everything it plays dangerously loud, and many headsets then feed the microphone back into the ears. So the listener records with AVCaptureSession, which never opens an output, and only from built-in and wired inputs (`TunerInput`). It also skips virtual inputs, which carry other apps' sound, and interface channels past 2, which can be loopback.
- **Screen Recording:** on recent macOS, `CGRequestScreenCaptureAccess()` shows no dialog. It only adds Yafie to the list in System Settings. The "bypass the system private window picker" alert comes with the first snip, then about once a month.

## Signing

Every build is signed with one self-signed certificate, **Yafie Code Signing**. macOS ties users' permissions (Accessibility, Microphone, Screen Recording) to it. Never sign a release with anything else, or ad hoc, and never make a new certificate, or everyone has to grant the permissions again. The Release workflow refuses any other certificate. See [docs/buildfromsource.md](docs/buildfromsource.md#signing).

## Versioning

Every update to the published package raises the version in `Resources/Info.plist` (`CFBundleShortVersionString`):

- **A new feature**, one that gets its own section in the README, like the screenshot tool was: the next 0.x.0, with the last number back to 0. For example, 0.8.3 → 0.9.0.
- **Anything else**, including fixes and additions to an existing feature, like a new tool in the snip editor: 0.0.1 more. For example, 0.8.0 → 0.8.1.

**Raise it as part of every change**, without being asked. Count from the published version in `downloads/latest.json` (none before the first release), not from `Info.plist`. Changes that go out together share one raise, and if any of them is a new feature, that raise is to the next 0.x.0.

**Don't commit or push.** The user commits and pushes with GitHub Desktop. Pushing a new version to main publishes it to everyone: the Release workflow builds, signs and publishes the installer, and Check for Updates offers it. See [docs/buildfromsource.md](docs/buildfromsource.md#release-an-update).

- **After a release,** the workflow pushes a commit of its own with the installer, `downloads/latest.json` and the README's version line, so the local copy is behind until that's pulled.
- **Leave `downloads/` alone.** Don't build or commit it by hand.
- **The README's version line** (`Version 0.8.0 · …`) is rewritten by `build.sh`. Keep its format, or change the `sed` in `build.sh` to match.

## Docs

- **[README.md](README.md)** is for users, and lean. Each feature has the same parts: what it does, **Turn it on**, then **Use it**. Update it, and [docs/troubleshooting.md](docs/troubleshooting.md), with every change users will see.
- **`docs/ideas/`** holds specs for features before they're built. It's gitignored, so specs stay local.
- **Code style:** short, sparse comments, and lines of 120 columns at most. Match the code around you.
