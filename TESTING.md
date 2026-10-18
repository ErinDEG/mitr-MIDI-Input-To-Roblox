# Testing MITR

## Automated checks

Build with `zsh build.command`, then run:

```bash
./MITR.app/Contents/MacOS/MITR --self-test
./MITR.app/Contents/MacOS/MITR --list-midi
codesign --verify --deep --strict MITR.app
```

The v1.6 test suite contains **147 checks**. It covers all 61 keys, live MIDI parsing, note-off/tap handling, sustain, channel/source isolation, real CoreMIDI packets from a temporary virtual source, Standard MIDI file parsing and errors, Humanize note pairing, range fitting, seek checkpoints and held-note restoration, countdowns, pause/resume, focus loss, scheduler stalls, speed bounds/timing, and song completion.

CoreMIDI integration requires the normal macOS service. Tests may fail those integration checks inside a restricted sandbox. No test sends keyboard output into Roblox. Automated checks cannot establish hardware compatibility or in-game audio behavior.

## Manual smoke test

1. Open the app. Check MIDI device discovery and the note/key display with a physical keyboard if available.
2. Grant Accessibility for the current app. Open **Test**, click **Start** in the main window, focus the test window, and play notes. Confirm key-down/up events appear and **Release all** clears holds.
3. Import **Playback Test.mid**. Confirm its four-second duration. Start playback, focus Test during the initial countdown, and confirm generated events stop at completion.
4. Import **Visualizer Demo.mid**. Confirm falling bars align with the 61-key keyboard and the song position advances during playback.
5. Drag the seek bar and scroll the roll in each direction. Confirm notes, playback, and both windows use the same position without replaying skipped events.
6. Toggle Humanize, change its amount, and verify replay. Check octave fitting with a file containing notes below MIDI 36 and above MIDI 96.
7. Check 100 → 110 → 100 → 90 → 100% speed. Check bounds 10–300%, unchanged pitch, pause/resume, and seeking at a changed speed.
8. Toggle dark theme in both windows. Restart and confirm theme and resume-countdown preferences persist; speed starts at 100%.
9. In Roblox at a piano with chat closed, play live notes and a demo file. Switch to another app and confirm held keys release and file playback pauses.
10. Enter full-screen Roblox, open the overlay, and confirm it remains visible. Use its playback and seek controls while Roblox retains focus. Test instant resume and the optional countdown.
11. Stop, release all, and quit. Confirm no stuck notes.

Before the first public release, v1.6 passed 147/147 automated checks in a local macOS session. The UI, generated events in the native test receiver, seeking, speed controls, and both themes were checked. The user confirmed the overlay remained visible over full-screen Roblox. Different MIDI hardware and Roblox experiences still need their own checks.
