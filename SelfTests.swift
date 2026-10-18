import Foundation
import CoreMIDI

func runSelfTests() -> Int32 {
    var checks = 0
    var failures = 0
    func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(description)") }
    }
    check(PianoMap.whiteKeys.count == 36, "36 white keys")
    check((36...96).compactMap { PianoMap.key(note: $0) }.count == 61, "all 61 notes mapped")
    check((36...96).compactMap { PianoMap.key(note: $0)?.label }.count == Set((36...96).compactMap { PianoMap.key(note: $0)?.label }).count, "61 unique key labels")
    for (note, key) in [(36,"1"),(37,"!"),(40,"3"),(42,"$"),(48,"8"),(49,"*"),(53,"q"),(60,"t"),(61,"T"),(72,"s"),(84,"l"),(96,"m")] {
        check(PianoMap.key(note: note)?.label == key, "\(note) → \(key)")
    }
    check(PianoMap.key(note: 35) == nil && PianoMap.key(note: 97) == nil, "out-of-range notes ignored")
    check(PianoMap.key(note: 24, transpose: 12)?.label == "1", "transpose into range")
    check(PianoMap.noteName(60) == "C4", "scientific middle C")
    check(PianoMap.key(note: 60)?.code == 17, "middle C uses physical T key")
    var parser = MIDIParser()
    let split1 = parser.consume([0x90,60])
    let split2 = parser.consume([100,62,0,0xf8,64,127])
    check(split1.isEmpty && split2.count == 3, "split packets, running status, and real-time interleaving")
    check(split2.last == MIDIMessage(status: 0x90, a: 64, b: 127), "running status data preserved")
    check(parser.consume([0xf0,1,2,0xf8,3,0xf7,60,100]).isEmpty, "SysEx ignored and running status cleared")
    check(parser.consume([0xf2,1,2,0x91,61,100]).first?.channel == 1, "system common and channel parsing")
    check(parser.consume([0xc0,1,2]).count == 2, "single-byte channel messages")
    check(parser.consume([0xff]).first?.status == 0xff, "MIDI reset is preserved")
    var events: [String] = []
    var scheduled: [() -> Void] = []
    var allowed = true
    let engine = PianoEngine()
    engine.allowed = { allowed }
    engine.emit = { key, down in events.append(key.label + (down ? "↓" : "↑")) }
    engine.schedule = { _, action in scheduled.append(action) }
    func send(_ status: UInt8, _ a: UInt8, _ b: UInt8, source: Int = 1) {
        engine.receive(MIDIMessage(status: status, a: a, b: b), source: source)
    }
    send(0x90,60,100); send(0x90,64,100); send(0x90,67,100)
    check(engine.heldCount == 3, "triad holds three keys")
    send(0x90,60,0)
    check(events.last == "t↑" && engine.heldCount == 2, "zero-velocity note-on is note-off")
    engine.panic(); check(engine.heldCount == 0, "panic releases a chord")
    events.removeAll()
    send(0x90,36,100); send(0x90,37,100); send(0x80,36,0)
    check(events == ["1↓","1↑","!↓"], "shared physical key transfers ownership safely")
    send(0x80,37,0); check(events.last == "!↑", "sharp releases its own mapping")
    events.removeAll(); engine.pedalMode = .local
    send(0xb0,64,127); send(0x90,60,100); send(0x80,60,0)
    check(engine.heldCount == 1, "local sustain retains released note")
    send(0xb0,64,0); check(engine.heldCount == 0, "local pedal release clears sustained note")
    events.removeAll(); engine.pedalMode = .space
    send(0xb0,64,127); send(0xb1,64,127); send(0xb0,64,0)
    check(events == ["Space↓"], "pedals across channels do not release Space early")
    send(0xb1,64,0); check(events.last == "Space↑", "last pedal releases Space")
    events.removeAll(); engine.channel = 1
    send(0x90,60,100); check(events.isEmpty, "channel filter ignores other channels")
    send(0x91,60,100); check(engine.heldCount == 1, "channel filter accepts selected channel")
    send(0xb1,123,0); check(engine.heldCount == 0, "MIDI all-notes-off clears keys")
    engine.channel = nil; events.removeAll(); engine.transpose = 12
    send(0x90,48,100); check(events.first == "t↓", "engine applies transpose")
    engine.panic(); engine.transpose = 0; events.removeAll(); engine.tapMode = true
    send(0x90,60,100); send(0x90,60,100)
    check(scheduled.count == 2, "tap note-offs scheduled")
    scheduled[0](); check(engine.heldCount == 1, "old tap timer cannot cancel a retrigger")
    scheduled[1](); check(engine.heldCount == 0, "current tap timer releases key")
    engine.tapMode = false; events.removeAll()
    send(0x90,60,100); allowed = false; send(0x90,62,100)
    check(events == ["t↓","t↑"] && engine.heldCount == 0, "focus/permission gate releases old note and blocks new note")
    events.removeAll(); send(0x90,64,100); check(events.isEmpty, "monitor mode never emits a key")
    allowed = true; events.removeAll()
    send(0x90,60,100, source: 1); send(0x90,60,100, source: 2); send(0x80,60,0, source: 1)
    check(engine.heldCount == 1 && events.last == "t↓", "one source cannot release another source's key")
    engine.panic()
    engine.channel = 1
    send(0x91,60,100); send(0xff,0,0)
    check(engine.heldCount == 0, "MIDI reset releases keys even with a channel filter")

    runMIDIFileTests(check: { condition, description in check(condition, description) })

    // Exercise the actual macOS MIDI callback with a source created only for this test.
    let input = MIDIInput()
    check(input.error == nil, "CoreMIDI client and input port initialize")
    var endpoint: MIDIEndpointRef = 0
    let created = MIDISourceCreate(input.client, "MITR temporary self-test" as CFString, &endpoint)
    check(created == noErr, "temporary virtual MIDI source initializes")
    if created == noErr {
        defer { MIDIEndpointDispose(endpoint) }
        var received: [MIDIMessage] = []
        input.onMessage = { message, _ in received.append(message) }
        input.connect([MIDISourceInfo(endpoint: endpoint, name: "Test")])
        let capacity = 2048
        let memory = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        let first: [UInt8] = [0x90,60,100]
        packet = first.withUnsafeBufferPointer { MIDIPacketListAdd(list, capacity, packet, 0, first.count, $0.baseAddress!) }
        let longPacket: [UInt8] = Array(repeating: [UInt8(0x80),60,0], count: 200).flatMap { $0 }
        let added = longPacket.withUnsafeBufferPointer { MIDIPacketListAdd(list, capacity, packet, 1, longPacket.count, $0.baseAddress!) }
        check(added.pointee.length == 600, "test packet exceeds fixed 256-byte struct field")
        check(MIDIReceived(endpoint, list) == noErr, "virtual source sends packets")
        let deadline = Date().addingTimeInterval(2)
        while received.count < 201 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        check(received.count == 201, "actual MIDI callback reads multiple packets and >256 bytes without truncation")
        check(received.first == MIDIMessage(status: 0x90, a: 60, b: 100), "CoreMIDI preserves note-on")
        check(received.last == MIDIMessage(status: 0x80, a: 60, b: 0), "CoreMIDI preserves final note-off")
    }
    print("\(checks - failures)/\(checks) checks passed\(failures == 0 ? " — mapping, parser, note lifecycle, sustain, focus gate, and real CoreMIDI input." : ".")")
    return failures == 0 ? 0 : 1
}

func runMIDIFileTests(check: (Bool, String) -> Void) {
    func word(_ value: Int, _ count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
    }
    func file(_ tracks: [[UInt8]], division: Int = 480, format: Int = 1) -> Data {
        var bytes = Array("MThd".utf8) + word(6, 4) + word(format, 2) + word(tracks.count, 2) + word(division, 2)
        for track in tracks { bytes += Array("MTrk".utf8) + word(track.count, 4) + track }
        return Data(bytes)
    }
    let end: [UInt8] = [0,0xff,0x2f,0]
    let tempo: [UInt8] = [0,0xff,0x51,3,0x07,0xa1,0x20, 0x83,0x60,0xff,0x51,3,0x0f,0x42,0x40] + end
    let notes: [UInt8] = [0,0x90,60,100, 0x83,0x60,60,0, 0,64,100, 0x83,0x60,0x80,64,0] + end
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    func rejects(_ data: Data) -> Bool { do { _ = try MIDIFile.read(data); return false } catch { return true } }
    do {
        let song = try MIDIFile.read(file([tempo,notes]))
        check(song.noteCount == 2 && song.events.count == 4, "MIDI file merges tracks and running status")
        check(close(song.events[1].time, 0.5) && close(song.events[2].time, 0.5) && close(song.duration, 1.5), "tempo changes apply across tracks in seconds")
        let format0 = try MIDIFile.read(file([notes], format: 0))
        check(close(format0.duration, 1), "format 0 uses the default 120 BPM tempo")
        let smpte = try MIDIFile.read(file([notes], division: 0xe728))
        check(close(smpte.duration, 0.96), "SMPTE timing is independent of tempo")
        let drop = try MIDIFile.read(file([notes], division: 0xe328))
        check(close(drop.duration, 960 / (30000.0 / 1001 * 40)), "drop-frame SMPTE timing")
        let untouched = song.humanized(milliseconds: 0)
        check(zip(untouched.events, song.events).allSatisfy { $0.time == $1.time }, "zero humanization preserves exact timings")
        var sequence = [0.25,0.75]
        let human = song.humanized(milliseconds: 12, random: { sequence.removeFirst() })
        check(close(human.events[0].time, 0.003) && close(human.events[2].time, 0.509), "humanization gives individual notes different small delays")
        check(close(human.events[1].time - human.events[0].time, 0.5) && close(human.events[3].time - human.events[2].time, 1), "humanization keeps press and release durations paired")
        let repeated = MIDISong(events: [
            TimedMIDIEvent(time: 0, message: MIDIMessage(status: 0x90, a: 60, b: 100), order: 0),
            TimedMIDIEvent(time: 0.001, message: MIDIMessage(status: 0x80, a: 60, b: 0), order: 1),
            TimedMIDIEvent(time: 0.002, message: MIDIMessage(status: 0x90, a: 60, b: 100), order: 2),
            TimedMIDIEvent(time: 0.003, message: MIDIMessage(status: 0x80, a: 60, b: 0), order: 3)
        ], duration: 0.003, noteCount: 2)
        sequence = [1,0]
        let repeatedHuman = repeated.humanized(milliseconds: 20, random: { sequence.removeFirst() })
        check(repeatedHuman.events.map(\.order) == [0,1,2,3], "rapid repeated notes cannot be reordered by humanization")
        check(close(repeatedHuman.duration, 0.021), "humanized final note-off extends the playback duration")

        let player = MIDIFilePlayer(), engine = PianoEngine()
        var sent: [String] = [], released = 0
        engine.allowed = { true }
        engine.emit = { sent.append($0.label + ($1 ? "↓" : "↑")) }
        player.emit = { engine.receive($0, source: -1) }
        player.release = { released += 1; engine.panic() }
        player.load(song); player.play(now: 10)
        player.advance(now: 12.9, allowed: false)
        check(sent.isEmpty && player.state == .countdown, "countdown gives time to switch to Roblox")
        player.advance(now: 13, allowed: true)
        check(sent == ["t↓"] && player.state == .playing, "file playback sends mapped keys when countdown ends")
        player.advance(now: 13.1, allowed: false)
        check(player.state == .paused && sent.last == "t↑" && engine.heldCount == 0, "losing focus pauses playback and releases held keys")
        player.advance(now: 500, allowed: true)
        check(player.state == .paused && player.position == 0, "focus recovery cannot burst or restart paused playback")
        player.play(now: 501); player.advance(now: 504, allowed: true)
        check(player.state == .playing && sent.last == "t↓" && engine.heldCount == 1, "Resume restores the note held at the paused position")
        player.advance(now: 504.1, allowed: true)
        check(close(player.position, 0.1), "Resume discards elapsed time spent paused")
        player.stop()
        check(player.position == 0 && player.state == .stopped && engine.heldCount == 0, "Stop rewinds the song and releases resumed keys")
        player.play(now: 600); player.advance(now: 603, allowed: false)
        check(player.state == .paused && engine.heldCount == 0, "countdown never types into another app")
        player.stop(); player.play(now: 700); player.advance(now: 703, allowed: true)
        player.advance(now: 703.5, allowed: true)
        check(player.state == .paused && engine.heldCount == 0, "scheduler stalls pause without dumping queued notes")
        player.stop(); sent.removeAll(); player.play(now: 800); player.advance(now: 803, allowed: true)
        for step in 1...15 { player.advance(now: 803 + Double(step) / 10, allowed: true) }
        check(player.state == .finished && engine.heldCount == 0 && sent == ["t↓","t↑","u↓","u↑"], "song completion emits ordered keys and releases everything")
        player.play(now: 900); player.pause(); let count = sent.count
        player.advance(now: 1000, allowed: true)
        check(sent.count == count && released > 0, "pausing the countdown cancels its playback")
        player.stop(); sent.removeAll()
        player.play(now: 1100, resumeCountdown: false, allowed: true)
        check(player.state == .countdown && player.countdown == 3 && sent.isEmpty,
              "disabling the resume countdown preserves the initial start delay")
        player.advance(now: 1103, allowed: true); player.advance(now: 1103.1, allowed: true); player.pause()
        player.play(now: 1200, resumeCountdown: false, allowed: true)
        check(player.state == .playing && player.countdown == 0 && close(player.position, 0.1) && sent.last == "t↓",
              "instant resume immediately restores held notes at the paused position")
        player.advance(now: 1200.1, allowed: true)
        check(close(player.position, 0.2), "instant resume advances without counting time spent paused")
        player.pause(); let blockedResumeCount = sent.count
        player.play(now: 1300, resumeCountdown: false, allowed: false)
        check(player.state == .paused && engine.heldCount == 0 && sent.count == blockedResumeCount,
              "instant resume cannot type without the target app focused")
        player.play(now: 1400, resumeCountdown: true, allowed: true)
        check(player.state == .countdown && player.countdown == 3,
              "enabling the resume countdown retains the three-second delay")
        player.stop()
        check(rejects(Data("not midi".utf8)), "non-MIDI import is rejected")
        let speedPlayer = MIDIFilePlayer()
        var speedNotes: [MIDIMessage] = [], speedReleases = 0
        speedPlayer.emit = { speedNotes.append($0) }
        speedPlayer.release = { speedReleases += 1 }
        speedPlayer.load(song)
        check(speedPlayer.speedPercent == 100 && speedPlayer.playbackRate == 1, "file speed starts at 100 percent")
        speedPlayer.setSpeed(percent: 110, now: 0, allowed: true)
        check(speedPlayer.speedPercent == 110 && close(speedPlayer.playbackRate, 1.1), "speed increases by an exact ten percentage points")
        speedPlayer.setSpeed(percent: 100, now: 0, allowed: true)
        speedPlayer.play(now: 0); speedPlayer.advance(now: 3, allowed: true)
        speedPlayer.advance(now: 3.1, allowed: true)
        speedPlayer.setSpeed(percent: 200, now: 3.2, allowed: true)
        check(close(speedPlayer.position, 0.2), "changing speed accounts for elapsed time at the old rate without jumping")
        speedPlayer.advance(now: 3.3, allowed: true)
        check(close(speedPlayer.position, 0.4), "200 percent advances two song seconds per wall second")
        speedPlayer.advance(now: 3.36, allowed: true)
        check(speedNotes.count == 3 && speedNotes.last?.a == 64, "faster playback sends the correct note-on and release boundaries")
        speedPlayer.setSpeed(percent: 50, now: 3.36, allowed: true)
        speedPlayer.advance(now: 3.56, allowed: true)
        check(close(speedPlayer.position, 0.62), "50 percent advances half as quickly without changing pitches")
        speedPlayer.pause(); speedPlayer.setSpeed(percent: 10, now: 10, allowed: false)
        check(close(speedPlayer.position, 0.62) && speedPlayer.state == .paused, "changing speed while paused preserves the seek position")
        speedPlayer.play(now: 20, resumeCountdown: false, allowed: true)
        speedPlayer.advance(now: 20.2, allowed: true)
        check(close(speedPlayer.position, 0.64), "instant resume uses the selected slow speed")
        speedPlayer.seek(to: 1.4, now: 20.2, allowed: true)
        speedPlayer.advance(now: 20.4, allowed: true)
        check(close(speedPlayer.position, 1.42), "seeking keeps song-time coordinates at altered speeds")
        speedPlayer.setSpeed(percent: 300, now: 20.4, allowed: true)
        speedPlayer.advance(now: 20.45, allowed: true)
        check(speedPlayer.state == .finished && speedPlayer.position == song.duration && speedReleases > 0,
              "fast playback finishes at the song boundary and releases its notes")
        speedPlayer.stop(); speedPlayer.play(now: 100)
        speedPlayer.advance(now: 101, allowed: true)
        check(speedPlayer.countdown == 2, "playback speed does not shorten the wall-clock countdown")
        speedPlayer.setSpeed(percent: 50, now: 101, allowed: true)
        speedPlayer.advance(now: 103, allowed: true); speedPlayer.advance(now: 103.2, allowed: true)
        check(close(speedPlayer.position, 0.1), "countdown speed changes take effect when playback begins")
        speedPlayer.pause(); speedPlayer.setSpeed(percent: -100, now: 103.2, allowed: false)
        check(speedPlayer.speedPercent == 10, "speed cannot reach zero or become negative")
        speedPlayer.setSpeed(percent: 10000, now: 103.2, allowed: false)
        check(speedPlayer.speedPercent == 300, "speed is bounded at 300 percent")
        speedPlayer.stop(); speedPlayer.play(now: 200); speedPlayer.advance(now: 203, allowed: true)
        speedPlayer.advance(now: 203.1, allowed: true)
        check(speedPlayer.state == .playing && close(speedPlayer.position, 0.3), "stall detection uses wall time even at maximum speed")
        speedPlayer.stop()
        check(rejects(file([notes], format: 2)), "independent format 2 tracks are rejected clearly")
        check(rejects(file([notes], division: 0)), "zero time division is rejected")
        check(rejects(file([notes], division: 0xe700)), "zero SMPTE ticks per frame is rejected")
        check(rejects(file([end])), "files without notes are rejected")
        check(rejects(file([[0,0x90,60,100]])), "unterminated tracks are rejected")
        check(rejects(file([[0,60,100] + end])), "running status without a status byte is rejected")
        check(rejects(file([[0x81,0x80,0x80,0x80,0,0x90,60,100] + end])), "oversized variable-length values are rejected")
        check(rejects(file([[0,0x90,60,0xff] + end])), "invalid note data is rejected")
        check(rejects(file([[0,0xff,0x51,3,0,0,0] + notes])), "zero tempo is rejected")
        func pitches(_ pitches: [Int]) -> MIDISong {
            var events: [TimedMIDIEvent] = []
            for (index, pitch) in pitches.enumerated() {
                events.append(TimedMIDIEvent(time: 0, message: MIDIMessage(status: 0x90, a: UInt8(pitch), b: 100), order: index))
            }
            for (index, pitch) in pitches.enumerated() {
                events.append(TimedMIDIEvent(time: 0.2 + Double(index) * 0.001,
                    message: MIDIMessage(status: 0x80, a: UInt8(pitch), b: 0), order: index + pitches.count))
            }
            return MIDISong(events: events, duration: 1, noteCount: pitches.count)
        }
        func onNotes(_ song: MIDISong) -> [Int] {
            song.events.filter { $0.message.kind == 0x90 && $0.message.b > 0 }.map { Int($0.message.a) }
        }
        let unchanged = song.fittedToPiano()
        check(unchanged.movedNotes == 0 && zip(song.events, unchanged.song.events).allSatisfy {
            $0.time == $1.time && $0.message == $1.message
        }, "already-fitting files keep notes, timing, velocity, and releases")
        let low = pitches([24,36,72]).fittedToPiano()
        check(low.octaveShift == 1 && low.foldedNotes == 0 && onNotes(low.song) == [36,48,84], "low arrangements shift together by an octave without changing intervals")
        let high = pitches([72,96,108]).fittedToPiano()
        check(high.octaveShift == -1 && high.foldedNotes == 0 && onNotes(high.song) == [60,84,96], "high arrangements shift together by an octave")
        let wide = pitches([24,60,108]).fittedToPiano()
        check(wide.foldedNotes == 1 && onNotes(wide.song).allSatisfy { (36...96).contains($0) }, "wide files fold remaining outliers into C2–C7")
        check(zip([24,60,108], onNotes(wide.song)).allSatisfy { (($1 - $0) % 12) == 0 }, "automatic fitting preserves pitch classes and musical key")
        let allPitches = pitches(Array(0...127))
        let allFit = allPitches.fittedToPiano()
        check(Set(onNotes(allFit.song)) == Set(36...96), "the complete MIDI note range maps into exactly the 61 supported pitches")
        check(allFit.mergedNotes == 67 && allFit.song.noteCount == 61, "folded overlapping duplicates are combined")
        check(allFit.song.events.allSatisfy { (36...96).contains(Int($0.message.a)) }, "note-off messages fit the same range as note-ons")
        var transposeFits = true, transposedKeysPreserved = true
        for transpose in -36...36 {
            for pitch in 0...127 {
                let fit = pitches([pitch]).fittedToPiano(transpose: transpose)
                let note = onNotes(fit.song)[0]
                transposeFits = transposeFits && (36...96).contains(note)
                transposedKeysPreserved = transposedKeysPreserved && (note - pitch - transpose) % 12 == 0
            }
        }
        check(transposeFits, "every MIDI pitch fits at every supported transpose setting")
        check(transposedKeysPreserved, "manual semitone transpose keeps its pitch class through automatic fitting")
        let collision = pitches([24,36,96]).fittedToPiano()
        let sharedOffs = collision.song.events.filter { $0.message.kind == 0x80 && $0.message.a == 36 }
        check(collision.mergedNotes == 1 && sharedOffs.count == 1 && close(sharedOffs[0].time, 0.201), "a folded duplicate stays held until its last original owner releases")
        let channelSong = MIDISong(events: [
            TimedMIDIEvent(time: 0, message: MIDIMessage(status: 0x90, a: 24, b: 99), order: 0),
            TimedMIDIEvent(time: 0, message: MIDIMessage(status: 0x91, a: 36, b: 100), order: 1),
            TimedMIDIEvent(time: 0, message: MIDIMessage(status: 0x91, a: 96, b: 101), order: 2),
            TimedMIDIEvent(time: 0.2, message: MIDIMessage(status: 0x80, a: 24, b: 0), order: 3),
            TimedMIDIEvent(time: 0.3, message: MIDIMessage(status: 0x91, a: 36, b: 0), order: 4),
            TimedMIDIEvent(time: 0.4, message: MIDIMessage(status: 0x81, a: 96, b: 0), order: 5),
            TimedMIDIEvent(time: 0.5, message: MIDIMessage(status: 0xb0, a: 64, b: 127), order: 6)
        ], duration: 1, noteCount: 3)
        let channelFit = channelSong.fittedToPiano()
        check(channelFit.song.noteCount == 3 && channelFit.mergedNotes == 0, "notes on different channels remain independent after octave folding")
        check(channelFit.song.events.last?.message == channelSong.events.last?.message, "range conversion preserves pedal messages")
        check(channelSong.fittedToPiano(channel: 0).octaveShift == 1, "the selected channel determines the best octave shift")
        let fitEngine = PianoEngine()
        fitEngine.allowed = { true }
        var fitPresses = 0, fitReleases = 0
        fitEngine.emit = { _, down in if down { fitPresses += 1 } else { fitReleases += 1 } }
        for event in allFit.song.events { fitEngine.receive(event.message, source: -1) }
        check(fitEngine.heldCount == 0 && fitPresses == 61 && fitReleases == 61, "converted files play through the key engine without dropped or stuck releases")
        let fitHuman = allFit.song.humanized(milliseconds: 8, random: { 0.5 })
        check(onNotes(fitHuman) == onNotes(allFit.song), "Humanize preserves the converted 61-note mapping")
        let timeline = PianoTimeline(song: song)
        check(timeline.noteCount == 2, "visualizer pairs note-ons and note-offs into duration bars")
        let firstVisible = timeline.visible(from: 0.1, through: 0.2)
        check(firstVisible.count == 1 && firstVisible[0].pitch == 60 && close(firstVisible[0].end, 0.5), "visualizer includes notes that started before the visible window")
        let nextVisible = timeline.visible(from: 0.5, through: 0.5)
        check(nextVisible.count == 1 && nextVisible[0].pitch == 64 && close(nextVisible[0].end, 1.5), "visualizer changes active notes at the exact playback boundary")
        check(timeline.visible(from: 1.5, through: 10).isEmpty, "visualizer excludes notes that have already ended")
        let humanTimeline = PianoTimeline(song: human)
        let humanFirst = humanTimeline.visible(from: 0, through: 0.004)
        check(humanFirst.count == 1 && close(humanFirst[0].start, 0.003) && close(humanFirst[0].end, 0.503), "visualizer uses the same humanized press and release times as output")
        let channelTimeline = PianoTimeline(song: channelSong, channel: 1)
        check(channelTimeline.noteCount == 2 && channelTimeline.visible(from: 0, through: 1).allSatisfy { $0.channel == 1 }, "visualizer follows the selected MIDI channel")
        let laneModels = (36...96).compactMap { PianoLane.forNote($0) }
        check(laneModels.filter { !$0.black }.count == 36 && laneModels.filter(\.black).count == 25, "visualizer draws all 61 keys with the correct white and black split")
        check(laneModels.allSatisfy { $0.x >= 0 && $0.x + $0.width <= 36 }, "all note bars align within the keyboard bounds")
        check(PianoLane.forNote(36)?.x == 0 && PianoLane.forNote(96)?.x == 35 && PianoLane.forNote(37)?.black == true, "keyboard lane geometry aligns C2, C-sharp, and C7")
        let dangling = MIDISong(events: [TimedMIDIEvent(time: 0, message: MIDIMessage(status: 0x90, a: 60, b: 100), order: 0)], duration: 2, noteCount: 1)
        check(PianoTimeline(song: dangling).visible(from: 1, through: 1).first?.end == 2, "unreleased visual notes end at the song boundary")
        let retriggered = MIDISong(events: [
            TimedMIDIEvent(time: 0, message: MIDIMessage(status: 0x90, a: 60, b: 100), order: 0),
            TimedMIDIEvent(time: 0.25, message: MIDIMessage(status: 0x90, a: 60, b: 100), order: 1),
            TimedMIDIEvent(time: 0.5, message: MIDIMessage(status: 0x80, a: 60, b: 0), order: 2)
        ], duration: 10, noteCount: 2)
        let retriggerTimeline = PianoTimeline(song: retriggered)
        check(retriggerTimeline.noteCount == 2 && retriggerTimeline.visible(from: 0.6, through: 10).isEmpty,
              "retriggered keys match engine ownership without lingering visual bars")

        let seekPlayer = MIDIFilePlayer(), seekEngine = PianoEngine()
        var seekKeys: [String] = []
        seekEngine.allowed = { true }
        seekEngine.emit = { seekKeys.append($0.label + ($1 ? "↓" : "↑")) }
        seekPlayer.emit = { seekEngine.receive($0, source: -1) }
        seekPlayer.release = { seekEngine.panic() }
        seekPlayer.load(song)
        seekPlayer.seek(to: 0.75, now: 1, allowed: false)
        check(seekPlayer.state == .paused && close(seekPlayer.position, 0.75) && seekKeys.isEmpty, "seeking while stopped previews the destination without sending keys")
        seekPlayer.play(now: 2); seekPlayer.advance(now: 5, allowed: true)
        check(seekKeys == ["u↓"] && close(seekPlayer.position, 0.75), "Play resumes from a seek destination and restores only its held note")
        seekPlayer.seek(to: 0.25, now: 5, allowed: true)
        check(seekKeys == ["u↓","u↑","t↓"] && close(seekPlayer.position, 0.25), "backward seek releases the old note and restores the destination immediately")
        seekPlayer.seek(to: 0.5, now: 5.1, allowed: true)
        check(seekKeys.suffix(3) == ["t↓","t↑","u↓"], "seeking onto a note boundary emits the boundary once in order")
        let seekCount = seekKeys.count
        seekPlayer.advance(now: 5.15, allowed: true)
        check(seekKeys.count == seekCount, "seeking does not replay skipped events or duplicate boundary notes")
        seekPlayer.seek(to: 1.2, now: 5.2, allowed: false)
        check(seekPlayer.state == .paused && seekEngine.heldCount == 0 && close(seekPlayer.position, 1.2), "seeking without target focus releases keys and stays paused")
        seekPlayer.seek(to: -10, now: 6, allowed: false)
        check(seekPlayer.position == 0, "backward scrolling clamps to the start")
        seekPlayer.seek(to: 100, now: 6, allowed: false)
        check(seekPlayer.position == song.duration && seekPlayer.state == .finished, "forward scrolling clamps to the end")
        seekPlayer.seek(to: .nan, now: 6, allowed: false)
        check(seekPlayer.position == 0 && seekPlayer.state == .paused, "invalid seek destinations cannot corrupt playback time")
        seekPlayer.stop(); seekPlayer.play(now: 10)
        seekPlayer.advance(now: 11, allowed: false)
        seekPlayer.seek(to: 0.75, now: 11, allowed: false)
        check(seekPlayer.state == .countdown && close(seekPlayer.countdown, 2), "seeking during the countdown preserves its remaining delay")
        seekPlayer.advance(now: 13, allowed: true)
        check(close(seekPlayer.position, 0.75) && seekPlayer.state == .playing, "countdown starts playback at the selected destination")

        var longEvents: [TimedMIDIEvent] = []
        for index in 0..<1500 {
            longEvents.append(TimedMIDIEvent(time: Double(index) * 0.1, message: MIDIMessage(status: 0x90, a: 60, b: 100), order: index * 2))
            longEvents.append(TimedMIDIEvent(time: Double(index) * 0.1 + 0.05, message: MIDIMessage(status: 0x80, a: 60, b: 0), order: index * 2 + 1))
        }
        let longSong = MIDISong(events: longEvents, duration: 150, noteCount: 1500)
        seekPlayer.load(longSong); seekKeys.removeAll()
        seekPlayer.seek(to: 149.92, now: 20, allowed: false)
        seekPlayer.play(now: 21); seekPlayer.advance(now: 24, allowed: true)
        check(seekKeys == ["t↓"] && close(seekPlayer.position, 149.92), "checkpoint seeking restores the right state far into a large song")
        check(PianoTimeline(song: longSong).visible(from: 149.91, through: 150).count == 1, "visualizer lookup finds only nearby bars after a long seek")
        seekPlayer.stop()
        let pedalSong = MIDISong(events: [
            TimedMIDIEvent(time: 0, message: MIDIMessage(status: 0xb0, a: 64, b: 127), order: 0),
            TimedMIDIEvent(time: 0.1, message: MIDIMessage(status: 0x90, a: 60, b: 100), order: 1),
            TimedMIDIEvent(time: 0.2, message: MIDIMessage(status: 0x80, a: 60, b: 0), order: 2),
            TimedMIDIEvent(time: 0.8, message: MIDIMessage(status: 0xb0, a: 64, b: 0), order: 3)
        ], duration: 1, noteCount: 1)
        seekEngine.pedalMode = .local; seekPlayer.localSustain = true
        seekPlayer.load(pedalSong); seekKeys.removeAll()
        seekPlayer.seek(to: 0.6, now: 30, allowed: false)
        check(seekKeys.isEmpty, "seeking over pedal messages does not emit skipped sustain or notes")
        seekPlayer.play(now: 31); seekPlayer.advance(now: 34, allowed: true)
        check(seekKeys == ["t↓"] && seekEngine.heldCount == 1, "seeking restores notes still held by local sustain")
        seekPlayer.advance(now: 34.2, allowed: true)
        check(seekEngine.heldCount == 0 && seekKeys.last == "t↑", "restored sustain notes release at the destination pedal-up")
        seekPlayer.stop()
        let valid = file([tempo,notes])
        check((0..<valid.count).allSatisfy { rejects(Data(valid.prefix($0))) }, "all truncated file prefixes fail safely")
    } catch { check(false, "MIDI file tests: \(error.localizedDescription)") }
}
