# MicGate: one mute button for every mic on your Mac

A tiny macOS menu-bar app that mutes your microphones **at the source**, so Zoom,
Google Meet, Teams, meeting recorders and every other app hear silence, no matter
what their own mute buttons say.

## Why

Mute buttons in call apps only mute *that app*. And apps can pick their own mic:
you might mute your headset while a recorder is quietly listening through the
built-in mic. MicGate mutes the devices themselves, all of them, and keeps them
muted. If any app tries to unmute a mic, MicGate mutes it again.

## Features

- Mutes **every physical mic** (built-in, USB, Bluetooth), including ones you
  plug in later. Virtual devices (BlackHole, Loopback, etc.) are left alone, so
  audio routing keeps working.
- Re-mutes instantly if an app turns a mic back on.
- Menu-bar icon turns red while muted, and a large "You are muted" popup shows
  when you toggle.
- Several ways to toggle:
  - **Hold** the menu-bar icon for half a second
  - **⌘-click** the menu-bar icon
  - Two keyboard shortcuts you can change in **Settings…**. The defaults are
    **⌃⌥⌘M** and **⌘ + the mic (dictation) key** on Mac keyboards (this is
    really ⌘F5).
- A plain click opens the menu. The mic key on its own still does
  dictation/Siri as normal.

## Changing shortcuts

Click the menu-bar icon, then **Settings…** (or press ⌘, while the menu is open).
Click **Record** next to a shortcut and press the keys you want. Esc cancels,
**Clear** removes a shortcut, and **Reset to defaults** restores ⌃⌥⌘M and ⌘F5.

Shortcuts need a modifier key (⌘ ⌥ ⌃ ⇧) unless they are F-keys or special keys.
With Accessibility allowed, shortcuts are caught before other apps, so they can
even replace system shortcuts like ⌘F5.

## Install

Requires macOS 13 or newer and the Xcode Command Line Tools
(`xcode-select --install` if you don't have them).

```bash
git clone https://github.com/19007361/macbook-universal-mic.git
```

```bash
cd macbook-universal-mic && ./install.sh
```

This builds the app from source, copies it to `~/Applications`, and starts it at
every login.

**One-time permission** (needed for shortcuts that clash with system shortcuts,
like the default ⌘ + mic key):
System Settings › Privacy & Security › Accessibility › switch **MicGate** on.
If it isn't active, the menu and Settings window show a ⚠︎ line.

If you rebuild later, macOS may forget this permission. To avoid that, see the
signing note at the top of `build.sh`.

## Uninstall

```bash
./uninstall.sh
```

## Good to know

- Muted means muted for dictation too. Unmute before dictating.
- Some mics have no mute or volume control macOS can use. If so, the menu lists
  them under "Can't mute".
- ⌘F5 from any keyboard is captured by MicGate (macOS normally uses it for
  VoiceOver).
- Choosing **Quit** from the menu unmutes your mics.
- The app is ad-hoc signed, not notarized by Apple. That's why you build it
  yourself from the single source file in `src/main.swift`.

## How it works

MicGate uses CoreAudio to set the input **mute** flag and input **volume to 0** on
every non-virtual input device. It listens for changes to those properties and
to the device list, and re-applies the mute whenever anything changes them.
Volumes are remembered and restored when you unmute.

## Privacy

MicGate never records, reads or sends audio, and makes no network connections.
The Accessibility permission is used only to catch ⌘F5.

## Build only

```bash
./build.sh
```

The app lands in `build/MicGate.app`.

## License

MIT. See [LICENSE](LICENSE).
