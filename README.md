# MITR

A native macOS app that turns MIDI piano notes into keyboard input for Roblox pianos. Play a real MIDI keyboard or import a MIDI file, follow a falling-note visualizer, and control playback from an overlay over full-screen Roblox.

**macOS 13 or later · Apple silicon (M1 or newer) · MIT License**

## Download and install

1. Download **[MITR-Mac.zip](https://github.com/ErinDEG/MITR/releases/latest/download/MITR-Mac.zip)** from the [latest release](https://github.com/ErinDEG/MITR/releases/latest).
2. Unzip it and move **MITR.app** to a permanent location, such as Applications. Keep the other files if you want the source and demo songs.
3. Open MITR. This release is ad-hoc signed and is **not notarized**. If macOS blocks opening it, review the app/source and use **System Settings → Privacy & Security → Open Anyway** for this app if you choose to trust it. Do not disable Gatekeeper globally.
4. In **System Settings → Privacy & Security → Accessibility**, add and enable **MITR.app**. This is required to generate piano keystrokes. Relaunch MITR if needed.
5. Open the installed Roblox client and use the keyboard.

No Python, package manager, extra libraries, or account is needed by MITR. A MIDI keyboard is optional for file playback. This prebuilt release supports Apple silicon; an Intel build is not provided.

## Quick start

### Play your MIDI keyboard

Connect the keyboard with a USB MIDI data cable or MIDI interface. For Bluetooth MIDI, connect it in macOS Audio MIDI Setup first. Select your input in MITR, click **Start**, then focus Roblox and play. A headphone/audio cable does not carry MIDI.

### Play a MIDI file

Click **Import…** and select a `.mid` or `.midi` file. Click **Play** and switch to Roblox during the three-second start countdown. Try the included **Playback Test.mid** or **Visualizer Demo.mid** first. The demo files are original examples distributed under the same MIT license.

Click **Overlay** for the compact floating player. Its mouse controls preserve Roblox focus and it can stay visible over full-screen Roblox. Use **Pause/Resume**, drag the progress bar to seek, or scroll over the piano roll (up = backward, down = forward). Switching to another app pauses playback and releases keys.

For the full guide, see **[START-HERE.md](START-HERE.md)**.

## Features

- Live MIDI input with device/channel selection, transpose, note holds or short taps, and three sustain modes.
- Standard 61-note Virtual Piano layout, **C2–C7 / MIDI 36–96**.
- Automatic MIDI-file range fitting: choose a whole-song octave shift, then fold remaining outliers by octaves. The original file is unchanged.
- Standard MIDI file format 0/1, tempo maps, multiple tracks, running status, and SMPTE timing.
- Optional **Humanize** with subtle **1–20 ms** individual note delays and matched note releases.
- A synchronized falling-note piano roll, clickable/draggable progress bar, scroll seeking, and full-screen overlay.
- **Speed −/+** changes in **10 percentage points**, from **10% to 300%**, without changing pitch or rewinding.
- Optional three-second resume countdown, plus a fixed three-second initial start countdown.
- Light and dark themes. Theme and resume-countdown preferences are remembered.
- A local **Test** window for checking generated keyboard events.

## Key mapping

White keys, from low to high:

```text
1234567890qwertyuiopasdfghjklzxcvbnm
```

Black notes use Shift with the preceding white key. Examples:

| Piano note | MIDI | Key |
|---|---:|---|
| C2 | 36 | `1` |
| C♯2 | 37 | `Shift+1` (`!`) |
| C3 | 48 | `8` |
| C4 (middle C) | 60 | `t` |
| C♯4 | 61 | `Shift+t` (`T`) |
| C5 | 72 | `s` |
| C6 | 84 | `l` |
| C7 | 96 | `m` |

Game piano implementations vary. Velocity cannot be expressed through ordinary keystrokes. A white key and its neighboring sharp share one physical key, so they cannot be held independently; try Short taps for those passages. Very wide imported arrangements have some intervals narrowed by octave folding. Live MIDI notes outside the range after transpose are ignored.

## Troubleshooting

| Symptom | What to check |
|---|---|
| No MIDI notes appear | Use a data cable, check USB/MIDI mode and Audio MIDI Setup, then click Refresh. |
| MITR sees notes but Roblox is silent | Enable Accessibility for this exact app, click Start, focus the installed Roblox client, and close chat. |
| Permission is enabled but Start fails after an update/build | Quit MITR, remove its old Accessibility entry, add the current app again, then relaunch. Keep the app in one location. |
| Resume does not start from the main window | Focus Roblox and use the overlay, or enable the three-second resume countdown. |
| Playback pauses unexpectedly | Roblox must remain frontmost. Release physical Command, Control, Option, and Shift keys. |
| Notes or sustain sound wrong | Try Short taps or a different sustain mode. Check the game's piano layout. |
| File import is rejected | Export as Standard MIDI format 0 or 1. Limits: 32 MB, 24 hours, and 1,000,000 parsed MIDI track events. Format 2 and audio files are unsupported. |

## Build from source

Requirements: an Apple silicon Mac with macOS 13+, Apple's Command Line Tools (or Xcode), and the included files. All dependencies are Apple system frameworks: AppKit, SwiftUI, Foundation, CoreMIDI, CoreGraphics, and UniformTypeIdentifiers. There are no third-party package dependencies or API keys.

Install the Command Line Tools if they are not already present:

```bash
xcode-select --install
```

Download this repository using **Code → Download ZIP**, unzip it, and open Terminal in that folder. Or clone it with Git:

```bash
git clone https://github.com/ErinDEG/MITR.git
cd MITR
```

Build and launch:

```bash
zsh build.command
open MITR.app
```

The script compiles the Swift files, generates `Info.plist`, installs the icon, and ad-hoc signs `MITR.app`. It targets `arm64-apple-macos13.0`. You do not need an Xcode project or paid developer account. Rebuilding may require refreshing Accessibility permission. For wider distribution, use your own Apple Developer signing identity and notarization workflow.

## Tests

After building, run from the repository folder:

```bash
./MITR.app/Contents/MacOS/MITR --self-test
./MITR.app/Contents/MacOS/MITR --list-midi
codesign --verify --deep --strict MITR.app
```

The self-tests cover key mapping, MIDI parsing, note lifecycles, sustain, range fitting, playback timing, Humanize, seek-state restoration, countdowns, speed, and CoreMIDI integration. Run them in a normal local macOS session: a restricted environment without the CoreMIDI service may fail the integration checks. The tests do not send keystrokes to Roblox. See [TESTING.md](TESTING.md) for manual checks and validation notes.

## Source map

| File | Purpose |
|---|---|
| `PianoCore.swift` | Key map, live MIDI parser, note ownership, sustain, and output lifecycle |
| `MIDIInput.swift` | CoreMIDI device discovery and input connection |
| `MIDIFile.swift` | MIDI-file parsing, range fitting, Humanize, playback, speed, and seeking |
| `PianoRoll.swift` | Falling-note rendering, keyboard, and seek controls |
| `main.swift` | App UI, theme, permissions, keyboard output, test window, and overlay |
| `SelfTests.swift` | Built-in test suite and synthetic MIDI fixtures |
| `build.command` | Reproducible local app build and ad-hoc signing |
| `MITR.icns` | App icon |

## Privacy and use

MITR processes MIDI files and device input locally. It has no network requests, analytics, login, or background login item. Accessibility is used for generated key input. Output is gated to the frontmost Roblox client (`com.roblox.RobloxPlayer`) or MITR's own test window; it releases held keys when focus is lost. It cannot distinguish Roblox chat from a piano, so keep chat closed. Use it in experiences where automated piano input is allowed.

MITR is an independent project and is not affiliated with Roblox, Virtual Piano, or Synthesia. MIDI files you import remain subject to their own licenses.

## License

[MIT License](LICENSE). Copyright © 2026 ErinDEG. The license covers the included source, documentation, icon, and original demo MIDI files.
