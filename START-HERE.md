# MITR

Open **MITR.app**. This is a native Apple silicon Mac app for macOS 13 or
newer. There are no Python packages, accounts, or downloads needed to run it.

## First play

1. Connect your piano with a **USB MIDI data cable** or a MIDI-to-USB interface.
   A headphone/audio cable alone cannot carry MIDI. For a Bluetooth MIDI device,
   pair it first in macOS Audio MIDI Setup.
2. Open MITR. Select your keyboard, or leave **All MIDI inputs** selected.
3. Play a note. The center display shows the note and its Roblox key;
   the piano strip lights up. Monitoring works without keyboard permission.
4. Click **Start**. On first use, macOS may request keyboard permission. In **System Settings → Privacy & Security
   → Accessibility**, add/enable **MITR.app** using the + button if needed.
   This permission lets the app generate keyboard input. Keep the app in the
   same location after granting access. Relaunch it if macOS asks.
5. Click **Start**, then open Roblox, sit at an in-game piano, and close
   chat. Roblox must be the frontmost app. The bridge remains open in the background.
6. Play your real piano. Click **Stop**, **Release all**, or quit the app
   to stop. Switching away from Roblox releases the held keys automatically.

**Test** opens a local receiver window. After granting keyboard access,
click Start in the main window and then focus the test window. Play MIDI notes
to check real generated key events without entering a Roblox game.

## Play a MIDI file

1. In **MIDI file**, click **Import…** and choose a `.mid` or `.midi` file.
2. Optionally enable **Humanize**. The slider adds individual note delays of
   up to 1–20 milliseconds; **8 ms** is a subtle starting point. Note releases
   move with their presses to preserve note lengths. This changes timing only.
3. Click **Play**, then switch to your Roblox piano during the three-second
   countdown. Playback uses the same key mapping, transpose, channel, note and
   pedal settings as your real piano. Physical MIDI input is paused during file playback.
4. **Pause** keeps your position. The **3-second resume countdown** checkbox in the
   main window and overlay controls whether Resume waits or continues immediately.
   It starts unchecked and is saved between launches. Starting a song from the
   beginning still uses the three-second countdown. For instant resume, use the
   overlay while Roblox is focused; resuming from the main window stays paused
   until you use the overlay with Roblox focused (or enable the countdown).
   **Stop** rewinds and releases all notes. The main **Stop** and **Release all**
   also stop or pause file output.

Switching away from Roblox or the MITR Test window pauses the song and releases
held keys. Click **Resume** to continue. A file never types into other apps.
Keep Roblox chat closed. Humanize changes take effect on the next playback and
rewind the current song. Format 0 and 1 MIDI files, tempo changes, multiple tracks,
and SMPTE timing are supported. Format 2 files must first be exported as format 0 or 1.
The player supports files up to 32 MB and 24 hours long. No audio file or
synthesizer is required.

Imported files automatically fit the 61-note C2–C7 range. Files already in range
keep their pitches. MITR first chooses the whole-song octave shift that fits the
most notes (preferring no shift when equally good), then folds any remaining
outliers up or down by octaves. This preserves the musical key; a very wide
arrangement will have some intervals narrowed. Overlapping notes that become
the same pitch are combined and held until their last original release.
The file panel shows how many notes were adjusted; hover over that text for
the octave shift, folded-note count, and duplicate count. Your original MIDI
file is unchanged. Conversion happens before Humanize, and is recalculated
from the original whenever you change Transpose or Channel. Transpose applies
once, followed by octave fitting, so every file note still fits. Live keyboard
input keeps its existing transpose/range behavior.

## Piano roll, seeking, and full-screen Roblox

**Speed** starts at **100%** each time you open MITR. Use **+** and **−** in the
main window or overlay to change it by **10 percentage points** per click, from
10% to 300%. Speed changes take effect without rewinding, and affect file notes,
note holds, the progress bar, and the falling-note animation together. Pitch is
unchanged. The displayed times remain positions in the original song. Countdowns
still last three real seconds; live MIDI keyboard playing is unaffected.

**Dark theme** switches the app, piano roll, controls, and overlay between light
and dark appearances. The two windows share the setting, which is saved between
launches. New installations keep the white theme until you turn this option on.

The falling bars show the imported file after 61-key fitting and Humanize, aligned
with the keyboard below. Bars reach the blue line when their notes begin. Their
lengths show the key-hold durations. The view follows the selected MIDI channel.
You can import **Visualizer Demo.mid** for a short example with two colored parts.

- Drag or click the song-position slider to skip forward or backward.
- Scroll over the piano roll: up rewinds, down moves forward. Trackpad scrolling
  supports smaller adjustments. Both controls move playback and the visualizer
  together, and clamp at the beginning and end of the song.
- Seeking while stopped or paused previews the new position; Play starts there
  using the resume countdown setting. During playback, seeking in the overlay continues
  immediately at the new position. Old notes are released and the destination's
  held notes and sustain-pedal state are restored without replaying skipped events.
- Click **Overlay** for a compact, resizable floating player. It follows macOS
  Spaces and is configured to appear over full-screen Roblox. Drag its title bar
  to move it. The overlay's buttons, slider, and scroll controls work with the mouse
  while Roblox keeps keyboard focus. Closing it leaves the main app running.

Clicking the main MITR window still pauses output when Roblox loses focus. Use
the overlay to seek or pause without leaving Roblox. Keep the in-game piano
active and chat closed. Changing Humanize creates a new set of timing variations
and rewinds both the visualizer and playback.

## Standard mapping

This uses the common 61-note Virtual Piano QWERTY layout, from **C2 to C7**:

| Piano note | MIDI number | Computer key |
|---|---:|---|
| C2 | 36 | `1` |
| C♯2 | 37 | `Shift+1` / `!` |
| C3 | 48 | `8` |
| C4 — middle C | 60 | `t` |
| C♯4 | 61 | `Shift+t` / `T` |
| C5 | 72 | `s` |
| C6 | 84 | `l` |
| C7 | 96 | `m` |

White keys, low to high: `1234567890qwertyuiopasdfghjklzxcvbnm`.
Black notes use Shift with the preceding white key. Use the Mac **ABC / US**
keyboard layout. The app uses physical QWERTY key positions. Keyboard makers
sometimes call MIDI note 60 “C3” or “C5”; MITR calls it **C4**.

## Make it feel right

- **Transpose:** moves the incoming notes by semitones. −12 and +12 move one
  octave. Notes outside the output range are ignored; they are not clamped to
  another pitch.
- **Follow MIDI holds:** a key goes down with note-on and up with note-off.
- **Short taps:** each note makes a 45 ms key press. Try this when a Roblox
  piano expects taps or holds sound wrong. MIDI velocity is displayed, but
  computer keystrokes cannot express variable playing volume.
- **Sustain — Hold Space:** pedal CC64 holds Space while the pedal is down.
  Choose this for games with a hold-Space sustain control.
- **Sustain — Extend notes locally:** retains notes until pedal-up without
  sending Space. Use with Follow MIDI holds.
- **Ignore pedal:** useful if your game's sustain behavior differs.
- **MIDI channel:** listen on all channels, or select the one your keyboard uses.

Each Roblox piano can implement keys differently. This app cannot make the game
support notes, sustain, or chords that its piano does not support. A white note
and its adjacent sharp share a physical computer key (for example `1` and `!`),
so both cannot be held independently. MITR retriggers the latest one and
releases it safely. Short taps may suit such passages better. Do not hold Mac
modifier keys (Command, Control, Option, or Shift) while playing; input is paused
while those modifiers are down.

The bridge only sends keys to a frontmost Roblox client or its own keyboard
test window. It does not play audio, inject code into Roblox, read your typing,
record songs, access the network, or start at login. Close Roblox chat before
playing: the app cannot distinguish a piano from a chat box inside Roblox.

## If notes do not arrive

Check the data cable, keyboard power, and your keyboard's USB/MIDI mode. Press
Refresh. macOS should also list the device in Audio MIDI Setup → MIDI Studio.
If notes arrive but Roblox stays silent, check Accessibility permission, press
Start, and focus the actual Roblox client rather than its website. The app
supports the installed `com.roblox.RobloxPlayer` client.

## Source and rebuild

The complete Swift source is included beside `build.command`, which rebuilds the app with
Apple's Command Line Tools. Rebuilding changes the local signature; macOS may
require granting Accessibility again. The bundled app is locally built and ad-hoc
signed, rather than signed/notarized with an Apple Developer distribution identity.
If MITR is enabled in Accessibility but Start does nothing after a rebuild,
remove its old entry, add the current MITR.app again, and relaunch MITR.

Run automated checks from this folder:

```bash
./MITR.app/Contents/MacOS/MITR --self-test
./MITR.app/Contents/MacOS/MITR --list-midi
```

The tests include the full key map, MIDI parsing, note-off handling, tap timers,
sustain, source/channel isolation, focus gating, and actual CoreMIDI packets sent
through a temporary virtual MIDI source. Hardware input and game audio still
need to be checked with your own piano and Roblox experience.

Mapping reference: https://virtualpiano.net/how-to-play/
MIDI file format reference: https://midi.org/standard-midi-files
Native APIs: Apple's CoreMIDI and CoreGraphics frameworks.
