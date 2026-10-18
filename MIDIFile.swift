import Foundation

struct TimedMIDIEvent {
    let time: TimeInterval
    let message: MIDIMessage
    let order: Int
}

struct MIDISong {
    let events: [TimedMIDIEvent]
    let duration: TimeInterval
    let noteCount: Int

    func fittedToPiano(transpose: Int = 0, channel: Int? = nil) -> PianoFit {
        let notes = events.compactMap { event -> Int? in
            let message = event.message
            guard message.kind == 0x90, message.b > 0,
                  channel == nil || message.channel == channel else { return nil }
            return Int(message.a) + transpose
        }
        // Prefer a single octave shift: this keeps the key and intervals intact.
        // If the arrangement is wider than five octaves, keep the most notes in
        // their shared register and fold only the remaining notes by octaves.
        var shift = 0, bestCount = -1
        for candidate in stride(from: -144, through: 144, by: 12) {
            let count = notes.filter { (36...96).contains($0 + candidate) }.count
            if count > bestCount || (count == bestCount && abs(candidate) < abs(shift)) {
                bestCount = count; shift = candidate
            }
        }
        if notes.isEmpty { shift = 0 }
        func fitted(_ original: Int) -> Int {
            var note = original + transpose + shift
            while note < 36 { note += 12 }
            while note > 96 { note -= 12 }
            return note
        }
        var adjusted: [TimedMIDIEvent] = []
        // Different octaves can map to the same destination. Share that note
        // until every original owner releases it, avoiding premature note-offs.
        var owners: [Int: [Int: Int]] = [:]
        var moved = 0, folded = 0, merged = 0, count = 0
        for event in events {
            let message = event.message
            let isOn = message.kind == 0x90 && message.b > 0
            let isOff = message.kind == 0x80 || (message.kind == 0x90 && message.b == 0)
            if isOn || isOff {
                let original = Int(message.a), note = fitted(original)
                let key = message.channel * 128 + note
                let selected = channel == nil || message.channel == channel
                var active = owners[key] ?? [:]
                if isOn {
                    if selected {
                        if note != original { moved += 1 }
                        if !(36...96).contains(original + transpose + shift) { folded += 1 }
                    }
                    let collision = !active.isEmpty && active[original] == nil
                    active[original, default: 0] += 1; owners[key] = active
                    if collision { if selected { merged += 1 }; continue }
                    count += 1
                } else {
                    guard let heldCount = active[original] else { continue }
                    if heldCount > 1 { active[original] = heldCount - 1 }
                    else { active.removeValue(forKey: original) }
                    owners[key] = active.isEmpty ? nil : active
                    if !active.isEmpty { continue }
                }
                let mapped = MIDIMessage(status: message.status, a: UInt8(note), b: message.b)
                adjusted.append(TimedMIDIEvent(time: event.time, message: mapped, order: event.order))
            } else {
                if message.kind == 0xb0 && [120,121,123].contains(message.a) {
                    owners = owners.filter { $0.key / 128 != message.channel }
                }
                adjusted.append(event)
            }
        }
        let song = MIDISong(events: adjusted, duration: duration, noteCount: count)
        return PianoFit(song: song, octaveShift: shift / 12, movedNotes: moved,
                        foldedNotes: folded, mergedNotes: merged)
    }

    // Keep each release paired with its press, and preserve repeated-note order.
    func humanized(milliseconds: Double, random: () -> Double = { Double.random(in: 0...1) }) -> MIDISong {
        let amount = min(20, max(0, milliseconds)) / 1000
        guard amount > 0 else { return self }
        var offsets: [Int: [Double]] = [:]
        var previous: [Int: Double] = [:]
        var adjusted: [TimedMIDIEvent] = []
        for event in events {
            let message = event.message
            let id = message.channel * 128 + Int(message.a)
            var delay = 0.0
            if message.kind == 0x90 && message.b > 0 {
                delay = min(1, max(0, random())) * amount
                offsets[id, default: []].append(delay)
            } else if message.kind == 0x80 || (message.kind == 0x90 && message.b == 0) {
                if var pending = offsets[id], !pending.isEmpty {
                    delay = pending.removeFirst(); offsets[id] = pending
                }
            }
            var time = event.time + delay
            if message.kind == 0x80 || message.kind == 0x90 {
                time = max(time, previous[id] ?? 0)
                previous[id] = time
            }
            adjusted.append(TimedMIDIEvent(time: time, message: message, order: event.order))
        }
        adjusted.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        return MIDISong(events: adjusted, duration: max(duration, adjusted.last?.time ?? 0), noteCount: noteCount)
    }
}

struct PianoFit {
    let song: MIDISong
    let octaveShift: Int
    let movedNotes: Int
    let foldedNotes: Int
    let mergedNotes: Int
    var summary: String {
        movedNotes == 0 ? "61-key fit" : "61-key fit · \(movedNotes) notes adjusted"
    }
    var detail: String {
        "C2–C7. Octave shift: \(octaveShift > 0 ? "+" : "")\(octaveShift). " +
        "\(foldedNotes) notes folded by octaves; \(mergedNotes) overlapping duplicates combined."
    }
}

enum MIDIFileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

private struct MIDIReader {
    let bytes: [UInt8]
    var position = 0
    var remaining: Int { bytes.count - position }
    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw MIDIFileError.invalid("This MIDI file is incomplete.") }
        defer { position += 1 }; return bytes[position]
    }
    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw MIDIFileError.invalid("This MIDI file has an invalid chunk length.") }
        defer { position += count }; return Array(bytes[position..<(position + count)])
    }
    mutating func number(_ count: Int) throws -> Int {
        try take(count).reduce(0) { ($0 << 8) | Int($1) }
    }
    mutating func variable() throws -> Int {
        var result = 0
        for _ in 0..<4 {
            let next = try byte(); result = (result << 7) | Int(next & 0x7f)
            if next & 0x80 == 0 { return result }
        }
        throw MIDIFileError.invalid("This MIDI file has an invalid event length.")
    }
}

enum MIDIFile {
    static func read(_ data: Data) throws -> MIDISong {
        guard data.count <= 32 * 1024 * 1024 else { throw MIDIFileError.invalid("Choose a MIDI file smaller than 32 MB.") }
        var reader = MIDIReader(bytes: Array(data))
        guard try reader.take(4) == Array("MThd".utf8) else { throw MIDIFileError.invalid("Choose a standard .mid or .midi file.") }
        let headerSize = try reader.number(4)
        guard headerSize >= 6 else { throw MIDIFileError.invalid("The MIDI header is incomplete.") }
        let format = try reader.number(2), trackCount = try reader.number(2), division = try reader.number(2)
        guard format <= 1 else { throw MIDIFileError.invalid("Export this MIDI as format 0 or 1 before importing it.") }
        guard trackCount > 0, trackCount <= 1024, format != 0 || trackCount == 1 else {
            throw MIDIFileError.invalid("This MIDI file has an invalid track count.")
        }
        _ = try reader.take(headerSize - 6)
        var secondsPerTick: Double?
        if division & 0x8000 != 0 {
            let frames = -Int(Int8(bitPattern: UInt8(division >> 8))), ticks = division & 255
            guard [24,25,29,30].contains(frames), ticks > 0 else { throw MIDIFileError.invalid("The MIDI time division is invalid.") }
            secondsPerTick = 1 / ((frames == 29 ? 30000.0 / 1001 : Double(frames)) * Double(ticks))
        } else if division == 0 { throw MIDIFileError.invalid("The MIDI time division is invalid.") }
        struct Raw { let tick: Int; let order: Int; let message: MIDIMessage?; let tempo: Int? }
        var raw: [Raw] = [], endTick = 0, order = 0, notes = 0
        for _ in 0..<trackCount {
            guard try reader.take(4) == Array("MTrk".utf8) else { throw MIDIFileError.invalid("A MIDI track is missing.") }
            let length = try reader.number(4)
            var track = MIDIReader(bytes: try reader.take(length)), tick = 0
            var running: UInt8?
            var ended = false
            while track.remaining > 0 {
                tick += try track.variable()
                order += 1
                guard order <= 1_000_000 else { throw MIDIFileError.invalid("This MIDI file contains too many events.") }
                var status = try track.byte()
                var firstData: UInt8?
                if status < 0x80 {
                    firstData = status
                    guard let saved = running else { throw MIDIFileError.invalid("The MIDI running status is invalid.") }
                    status = saved
                }
                if status == 0xff {
                    running = nil
                    let kind = try track.byte(), size = try track.variable(), payload = try track.take(size)
                    if kind == 0x51 {
                        guard payload.count == 3 else { throw MIDIFileError.invalid("The MIDI tempo is invalid.") }
                        let tempo = payload.reduce(0) { ($0 << 8) | Int($1) }
                        guard tempo > 0 else { throw MIDIFileError.invalid("The MIDI tempo is invalid.") }
                        raw.append(Raw(tick: tick, order: order, message: nil, tempo: tempo))
                    }
                    if kind == 0x2f {
                        guard size == 0 else { throw MIDIFileError.invalid("The MIDI end marker is invalid.") }
                        ended = true; break
                    }
                } else if status == 0xf0 || status == 0xf7 {
                    running = nil
                    let size = try track.variable(); _ = try track.take(size)
                } else {
                    guard (0x80...0xef).contains(status) else { throw MIDIFileError.invalid("The MIDI file contains an unsupported event.") }
                    running = status
                    let a = try firstData ?? track.byte()
                    let b: UInt8 = [0xc0,0xd0].contains(status & 0xf0) ? 0 : try track.byte()
                    guard a < 128, b < 128 else { throw MIDIFileError.invalid("The MIDI note data is invalid.") }
                    let message = MIDIMessage(status: status, a: a, b: b)
                    if [0x80,0x90,0xb0].contains(message.kind) {
                        raw.append(Raw(tick: tick, order: order, message: message, tempo: nil))
                    }
                    if message.kind == 0x90 && b > 0 { notes += 1 }
                }
            }
            guard ended else { throw MIDIFileError.invalid("A MIDI track is missing its end marker.") }
            endTick = max(endTick, tick)
        }
        guard notes > 0 else { throw MIDIFileError.invalid("This MIDI file contains no notes.") }
        raw.sort { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }
        var events: [TimedMIDIEvent] = [], seconds = 0.0, tick = 0, tempo = 500_000
        func interval(_ ticks: Int) -> Double {
            Double(ticks) * (secondsPerTick ?? (Double(tempo) / 1_000_000 / Double(division)))
        }
        for event in raw {
            seconds += interval(event.tick - tick); tick = event.tick
            if let newTempo = event.tempo { tempo = newTempo }
            if let message = event.message { events.append(TimedMIDIEvent(time: seconds, message: message, order: event.order)) }
        }
        let duration = seconds + interval(endTick - tick)
        guard duration <= 24 * 3600 else { throw MIDIFileError.invalid("Choose a MIDI file shorter than 24 hours.") }
        return MIDISong(events: events, duration: duration, noteCount: notes)
    }
}

// Scheduling uses a monotonic clock. Pausing discards elapsed wall time, so returning
// to the game never sends a burst of all the notes missed while unfocused.
private struct MIDIPlaybackSnapshot {
    var held: [Int: MIDIMessage] = [:]
    var pedals: [Int: MIDIMessage] = [:]
    var sustained: [Int: MIDIMessage] = [:]
    mutating func consume(_ message: MIDIMessage) {
        let id = message.channel * 128 + Int(message.a)
        if message.kind == 0x90 && message.b > 0 { held[id] = message; sustained.removeValue(forKey: id) }
        else if message.kind == 0x80 || (message.kind == 0x90 && message.b == 0) {
            if let note = held.removeValue(forKey: id), pedals[message.channel] != nil { sustained[id] = note }
        }
        else if message.kind == 0xb0 && message.a == 64 {
            if message.b >= 64 { pedals[message.channel] = message }
            else {
                pedals.removeValue(forKey: message.channel)
                sustained = sustained.filter { $0.value.channel != message.channel }
            }
        } else if message.kind == 0xb0 && [120,121,123].contains(message.a) {
            held = held.filter { $0.value.channel != message.channel }; pedals.removeValue(forKey: message.channel)
            sustained = sustained.filter { $0.value.channel != message.channel }
        }
    }
}

final class MIDIFilePlayer {
    enum State { case stopped, countdown, playing, paused, finished }
    private(set) var state = State.stopped
    private(set) var position = 0.0
    private(set) var countdown = 0.0
    private var song: MIDISong?
    private var index = 0
    private var lastClock: Double?
    private var snapshot = MIDIPlaybackSnapshot()
    private var checkpoints: [MIDIPlaybackSnapshot] = []
    private var restoring = false
    var emit: (MIDIMessage) -> Void = { _ in }
    var release: () -> Void = {}
    var localSustain = false
    private(set) var speedPercent = 100
    var playbackRate: Double { Double(speedPercent) / 100 }
    var duration: Double { song?.duration ?? 0 }
    func setSpeed(percent: Int, now: Double, allowed: Bool) {
        // Account for elapsed time at the old rate before changing speed.
        if state == .playing || state == .countdown { advance(now: now, allowed: allowed) }
        speedPercent = min(300, max(10, (percent / 10) * 10))
    }
    func load(_ song: MIDISong) {
        stop(); self.song = song
        checkpoints = [MIDIPlaybackSnapshot()]
        var current = MIDIPlaybackSnapshot()
        for (index, event) in song.events.enumerated() {
            current.consume(event.message)
            if (index + 1) % 1024 == 0 { checkpoints.append(current) }
        }
    }
    func play(now: Double, resumeCountdown: Bool = true, allowed: Bool = false) {
        guard song != nil else { return }
        restoring = state == .paused
        if !restoring { position = 0; index = 0; snapshot = MIDIPlaybackSnapshot() }
        lastClock = now
        if restoring && !resumeCountdown {
            countdown = 0; state = .playing
            advance(now: now, allowed: allowed)
        } else { countdown = 3; state = .countdown }
    }
    func pause() {
        guard state == .playing || state == .countdown else { return }
        state = .paused; lastClock = nil; countdown = 0; release()
    }
    func stop() {
        state = .stopped; position = 0; index = 0; lastClock = nil; countdown = 0
        restoring = false; snapshot = MIDIPlaybackSnapshot(); release()
    }
    func seek(to destination: Double, now: Double, allowed: Bool) {
        guard let song else { return }
        let previousState = state
        release()
        position = destination.isFinite ? min(song.duration, max(0, destination)) : 0
        // Binary search plus checkpoints keeps scrubbing large files responsive.
        var low = 0, high = song.events.count
        while low < high {
            let middle = (low + high) / 2
            if song.events[middle].time < position { low = middle + 1 } else { high = middle }
        }
        let destinationIndex = low
        index = (destinationIndex / 1024) * 1024
        snapshot = checkpoints[destinationIndex / 1024]
        while index < destinationIndex { snapshot.consume(song.events[index].message); index += 1 }
        lastClock = now; restoring = true
        if position >= song.duration { state = .finished; countdown = 0; restoring = false }
        else if previousState == .countdown { state = .countdown }
        else if previousState == .playing && allowed { state = .playing; advance(now: now, allowed: true) }
        else { state = .paused; countdown = 0 }
    }
    func advance(now: Double, allowed: Bool) {
        defer { lastClock = now }
        guard state == .playing || state == .countdown, let song else { return }
        var elapsed = max(0, now - (lastClock ?? now))
        if state == .countdown {
            let remaining = countdown - elapsed
            countdown = max(0, remaining)
            if remaining > 0 { return }
            guard allowed else { pause(); return }
            state = .playing; elapsed = -remaining
        }
        guard allowed else { pause(); return }
        // A stalled main thread should pause rather than dump a backlog of keys.
        if elapsed > 0.25 { pause(); return }
        if restoring {
            for channel in snapshot.pedals.keys.sorted() { emit(snapshot.pedals[channel]!) }
            for note in snapshot.held.keys.sorted() { emit(snapshot.held[note]!) }
            if localSustain {
                for id in snapshot.sustained.keys.sorted() {
                    let note = snapshot.sustained[id]!
                    emit(note); emit(MIDIMessage(status: 0x80 | UInt8(note.channel), a: note.a, b: 0))
                }
            }
            restoring = false
        }
        position = min(song.duration, position + elapsed * playbackRate)
        while index < song.events.count && song.events[index].time <= position {
            let message = song.events[index].message
            snapshot.consume(message)
            emit(message); index += 1
        }
        if index == song.events.count && position >= song.duration { state = .finished; release() }
    }
}
