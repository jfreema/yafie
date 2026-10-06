# Troubleshooting

- **“Yafie.pkg” was blocked to protect your Mac.** Expected the first time, since the installer isn't signed. See [Install](../README.md#install).
- **No Yafie in the menu bar after Open Anyway.** macOS can get stuck approving the app, and then holds it before it starts, every time. Restart your Mac, or run `sudo killall syspolicyd`, then open Yafie again.
- **See what Yafie did:** `/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.jfreema.yafie"'`

## Stay awake with the lid closed

- **Check whether sleep is off right now:** `pmset -g | grep SleepDisabled` (`1` means off).
- **Turn sleep back on by hand:** `sudo pmset disablesleep 0`
- **Mac won't sleep after a crash or power loss.** If macOS crashes or loses power while sleep is off, the setting stays off through the restart until Yafie next starts and turns it back on. Open Yafie, or turn sleep back on by hand (above).
- **Another app with a closed-lid mode.** Don't use it at the same time as Yafie. Both apps change the same setting.
- **Sleeps even though you're online.** With **Only While Connected to the Internet** on, Yafie counts the Mac as offline when `https://captive.apple.com` doesn't load for about a minute, for example on a network that blocks it. Turn that option off.
- **Sleeps on battery.** **Only While Connected to Power** is on, or the battery is at 10% or less.
- **Two Yafie processes in Activity Monitor.** The one without an icon is the watchdog, which turns sleep back on if the app crashes. It ends by itself when the app quits.

## Guitar tuner

- **Says Yafie can't use the microphone.** Turn on Yafie in **System Settings → Privacy & Security → Microphone**, then click the tuner window to try again.
- **Asks for the microphone again after an update.** Expected once, when updating to 0.7.5: that's when Yafie got its own signing certificate, so macOS sees a new app. Allow it again. Later updates keep the permission.
- **Shows nothing when you play.** Check the input in **System Settings → Sound → Input**, and that its level moves when you play. Play closer to the microphone: an unplugged electric guitar is quiet.
- **Doesn't use your Bluetooth headset's microphone.** On purpose. Opening it switches the headset to call mode, which can make everything it plays suddenly much louder. The tuner uses the Mac's own microphone instead, or a wired one.
- **A third Yafie process in Activity Monitor while the tuner is open.** That's the tuner's listener. It listens in a process of its own, so a stuck audio device can't freeze Yafie, and it ends when you close the tuner.
## Window snapping

- **The menu shows Allow Window Snapping….** Yafie doesn't have the Accessibility permission. Choose it, then turn Yafie on in the list that opens.
- **"Another app is using a ⌃⌥ arrow key."** Another app, such as a window manager, has the same shortcut. Quit it or change its shortcut, then turn snapping off and on.
- **A window doesn't fill its column exactly.** Some apps keep a minimum size, and Terminal rounds to whole characters. Yafie centers those on the column and keeps them on the display.
- **A full-screen window doesn't move.** Yafie leaves full-screen windows alone. Leave full screen first.

## App preview

- **The menu shows Allow App Previews….** Yafie is missing the Accessibility permission, or Screen & System Audio Recording for the pictures. Choose it, and turn on Yafie in the list that opens. After Screen & System Audio Recording, click **Quit & Reopen**.
- **Titles but no pictures.** Yafie can't record the screen yet. See the item above.
- **Nothing appears over the Dock.** Check that Yafie is on in **Accessibility**, then turn **Show App Previews in the Dock** off and on.
- **A window is missing.** Only windows on the current desktop show, plus minimized ones. Full-screen windows, which have desktops of their own, and small panels like palettes don't.
- **The app's icon, or an old picture, instead of the window.** macOS can't picture minimized windows or a hidden app's windows, so they show the last picture Yafie took, or the app's icon.
- **macOS asks whether Yafie can bypass the system private window picker.** As with snips, click **Allow**. macOS asks again about once a month.

## Screenshot tool

- **The menu shows Allow Screen Snipping….** Yafie doesn't have the Screen & System Audio Recording permission. Choose it, turn on Yafie in the list that opens, then click **Quit & Reopen**.
- **Still shows Allow Screen Snipping… after you allowed it.** macOS only tells Yafie when it starts. Quit Yafie and open it again.
- **Nothing seems to happen when you turn on Snipping Tool.** macOS adds Yafie to its Screen & System Audio Recording list, switched off, without asking. Choose **Allow Screen Snipping…** in Yafie's menu to get there. See [Screenshot tool](../README.md#screenshot-tool).
- **The menu vanished on your first snip.** macOS asked whether Yafie can bypass the system private window picker, which closes the menu. Click **Allow**, then snip again.
- **macOS asks every month whether Yafie can record the screen.** Expected on macOS 15 and later, for every app that takes screenshots. Click **Allow**. If the snip you were taking comes out wrong, take it again.
- **"Another app is using ⌃⌥P."** Another app has the same shortcut. Quit it or change its shortcut, then turn snipping off and on.
- **An app's own ⌃⌥P stopped working.** While snipping is on, ⌃⌥P belongs to Yafie in every app. Turn snipping off to give it back.
