docs# MicGate: developer handoff

Notes for anyone picking up this project: what it does, how it's built, what was
learned along the way, and what's still open. User-facing docs are in
[README.md](README.md).

---

## 1. Goal

One mute switch for *every* microphone on a Mac, applied at the audio-device
level ("the first gate the sound passes through"). Call and recording apps
(Zoom, Google Meet, Teams, meeting note-takers, etc.) then hear silence no matter
what their own mute buttons say, and they can't unmute it.

## 2. Status

- Working menu-bar app, single Swift file (`src/main.swift`), no dependencies.
- Universal build (Apple silicon + Intel), targets macOS 13+.
- Developed and tested on macOS 15 (Apple silicon), using a USB headset mic plus
  the built-in MacBook mic, with a BlackHole virtual device present.
- Public repo: https://github.com/19007361/macbook-universal-mic

## 3. What the app does

- **Mutes every physical input device** (built-in, USB, Bluetooth). It skips
  virtual and aggregate devices (BlackHole, Loopback, etc.) so audio routing
  keeps working.
- Uses two levers per device, whichever the device supports: input **mute flag
  = 1** and input **volume = 0**. Volumes are saved per device UID and restored
  on unmute.
- **Enforcement:** CoreAudio property listeners watch mute and volume on every
  gated device. If any app unmutes or raises the volume, MicGate re-mutes
  straight away.
- **Hot-plug:** listens for device-list and default-input changes and rescans.
- **UI:**
  - Menu-bar mic icon, which turns into a red slashed mic when muted.
  - A large HUD popup under the menu bar on every toggle: "You are muted" in
    red, or "Mic is live" in green.
- **Ways to toggle:**
  - Hold the icon for about 0.45 s.
  - ⌘-click the icon.
  - Two configurable keyboard shortcuts. The defaults are ⌃⌥⌘M and ⌘F5
    (= ⌘ + the mic/dictation key).
  - A plain click or right-click opens the menu.
- **Menu:** Mute/Unmute, the gated mics, the shortcut summary, warnings
  (Accessibility off, or mics that can't be muted), Settings…, and Quit (which
  unmutes).
- **Settings window:**
  - Two shortcut slots, each with Record and Clear.
  - Reset to defaults.
  - An Accessibility status line, plus a button that opens the right pane of
    System Settings.
  - Shortcuts must include a modifier unless the key is an F-key or special
    key. Esc cancels recording.

## 4. Code map (`src/main.swift`)

| Section | Purpose |
|---|---|
| CoreAudio helpers | Property addresses, settable checks, device name and UID, default input, transport type, `physicalInputs()` |
| `Gate` | Owns the gated device list, applies the mute state, listens for changes and re-enforces, saves and restores volumes |
| `HUD` | Borderless, non-activating popup panel under the status item |
| `Shortcut` / `ShortcutStore` | Shortcut model (key code + modifier bits + label), display string, Carbon modifier mapping, stored in UserDefaults |
| `SettingsWindow` | Shortcut recorder UI |
| `App` | Status item, click/hold handling, key tap, Carbon hotkey fallback, menu, icon |
| Entry | `--selftest`, `--demo-hud`, `--demo-settings`, normal launch |

## 5. Key technical findings

1. **Muting only the default input is not enough.** Apps can choose their own
   mic. A meeting recorder kept hearing the built-in mic while only the headset
   (the default input) was muted. Hence the decision to gate every physical
   input.
2. **Mac keyboard mic key** (seen with a CGEventTap logger):
   - The mic/dictation key alone sends key code **176**. MicGate leaves it
     alone so dictation and Siri keep working.
   - **⌘ + mic key arrives as ⌘ + F5 (key code 96)**, with the fn flag set.
   - macOS uses ⌘F5 for **VoiceOver**, so without interception VoiceOver pops
     up.
3. **Shortcut handling:**
   - With Accessibility granted, a session `CGEventTap` (`.defaultTap`, head
     insert) sees configured shortcuts before other apps and before system
     shortcuts, and swallows them.
   - Without Accessibility, shortcuts fall back to Carbon `RegisterEventHotKey`,
     which can't override system combos like ⌘F5.
   - While a shortcut is being recorded, the tap captures the keys itself, so
     system combos can be recorded too.
4. **Ad-hoc signing resets Accessibility on every rebuild.** The ad-hoc
   designated requirement is the cdhash, so each build looks like a new app to
   macOS.
   - Fix: sign with a stable identity and a fixed identifier
     (`--identifier local.micgate`).
   - Two different builds signed that way get identical designated
     requirements.
   - `build.sh` supports this through `MICGATE_SIGN_IDENTITY`.
5. **Device controls vary.**
   - Some devices expose mute on the master element and volume on channel 1;
     others put both on master. The code checks elements 0–4.
   - Some devices expose neither. The menu lists those under "Can't mute".
   - AppleScript's `input volume` returned `missing value` for a USB headset, so
     the AppleScript route isn't reliable.
6. **UserDefaults domain gotcha.** Running the binary directly from a shell can
   use a different prefs domain than the launchd-started app (`local.micgate`).
   A self-test can then read a different "muted" flag. Stop the installed copy
   before self-testing, and check real device state afterwards.
7. **Red menu-bar icon.** `contentTintColor` on a template image was
   unreliable, so the code uses a palette-coloured, non-template SF Symbol.

## 6. Build, install, test

```bash
./build.sh                 # universal build -> build/MicGate.app (ad-hoc signed)
```

```bash
./install.sh               # builds if build/ is missing, installs to ~/Applications, adds LaunchAgent
```

```bash
./uninstall.sh
```

**Stable signing.** This keeps the Accessibility permission across rebuilds.
List your identities with `security find-identity -v -p codesigning`, then:

```bash
rm -rf build && MICGATE_SIGN_IDENTITY="<identity name or SHA-1>" ./install.sh
```

`install.sh` reuses an existing `build/`, which is why the command removes it
first.

**Self-test.** It mutes all mics, fakes an app unmuting them, checks they get
re-muted, then unmutes. Stop the installed copy first, and restart it
afterwards:

```bash
launchctl bootout gui/$(id -u)/local.micgate
```

```bash
build/MicGate.app/Contents/MacOS/MicGate --selftest
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.micgate.plist
```

**Visual checks.** These don't touch the mics: `--demo-hud` (add `live` for the
green version) and `--demo-settings`.

**Installed locations:**
- `~/Applications/MicGate.app`
- `~/Library/LaunchAgents/local.micgate.plist` (label `local.micgate`)
- Prefs domain `local.micgate`, with keys `muted`, `shortcuts` and
  `vol-<deviceUID>-<element>`

## 7. Design decisions

- Mute **all physical mics**, not just the default. The accepted trade-off is
  that the built-in mic is muted even while you use a headset.
- Leave **virtual devices** alone, so routing tools keep working.
- A plain click opens the menu rather than toggling, so a misclick can't change
  the mute state. Hold or ⌘-click toggles.
- The mic key alone keeps dictation and Siri. Only ⌘ + mic key toggles.
- The repo ships **source only**, with no prebuilt binary, so users build from
  code they can read.
- MIT licence.

## 8. Open items / not yet verified

1. Recording a new shortcut by hand in Settings (only the rendering was checked).
2. The ⌘ + mic key path end to end after granting Accessibility to a
   stable-signed build. The ⌃⌥⌘M path was verified by sending synthetic key
   events.
3. Hot-plugging a new mic while muted. The code handles it, but it wasn't
   tested by hand.
4. The Intel slice and the macOS 13 minimum, which weren't run.
5. `install.sh` on a fresh Mac.
6. Possible additions:
   - a GitHub Release with a prebuilt zip
   - a per-mic exclude list
   - a launch-at-login toggle inside the app
   - a configurable hold time
   - notarization

## 9. History

1. Explored the options: device-level mute, a virtual mic, or existing apps.
   Chose device-level mute.
2. First version muted the default input only, with a self-test, an install to
   `~/Applications` and a LaunchAgent.
3. Red muted icon. Hold and ⌘-click toggles. HUD popup.
4. Captured the mic-key codes, which showed ⌘ + mic key is ⌘F5. Added a key-tap
   shortcut that suppresses VoiceOver.
5. Found a recorder using a non-default mic, so switched to muting all physical
   mics.
6. Published publicly.
7. Added stable-signing support and a Settings window for changing shortcuts.
