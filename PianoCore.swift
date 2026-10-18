import Foundation

struct PianoKey: Equatable {
    let code: UInt16
    let shifted: Bool
    let label: String
}

enum PianoMap {
    static let whiteKeys = Array("1234567890qwertyuiopasdfghjklzxcvbnm")
    static let keyCodes: [Character: UInt16] = [
        "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
        "q":12,"w":13,"e":14,"r":15,"t":17,"y":16,"u":32,"i":34,"o":31,"p":35,
        "a":0,"s":1,"d":2,"f":3,"g":5,"h":4,"j":38,"k":40,"l":37,
        "z":6,"x":7,"c":8,"v":9,"b":11,"n":45,"m":46
    ]
    static let symbols: [Character: String] = ["1":"!","2":"@","3":"#","4":"$","5":"%","6":"^","7":"&","8":"*","9":"(","0":")"]
    static func key(note: Int, transpose: Int = 0) -> PianoKey? {
        let note = note + transpose
        guard (36...96).contains(note) else { return nil }
        let offset = note - 36
        let pitch = offset % 12
        let whites = [0,2,4,5,7,9,11]
        let index = (offset / 12) * 7 + whites.filter { $0 < pitch }.count
        let black = !whites.contains(pitch)
        let character = whiteKeys[index - (black ? 1 : 0)]
        return PianoKey(code: keyCodes[character]!, shifted: black,
                        label: black ? (symbols[character] ?? String(character).uppercased()) : String(character))
    }
    static func noteName(_ note: Int) -> String {
        let names = ["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"]
        return "\(names[((note % 12) + 12) % 12])\(note / 12 - 1)"
    }
}

struct MIDIMessage: Equatable {
    let status: UInt8
    let a: UInt8
    let b: UInt8
    var channel: Int { Int(status & 0x0f) }
    var kind: UInt8 { status & 0xf0 }
}

// A source keeps its own parser, including running status across packet boundaries.
struct MIDIParser {
    private var running: UInt8?
    private var data: [UInt8] = []
    private var systemRemaining = 0
    private var sysex = false
    mutating func consume(_ bytes: [UInt8]) -> [MIDIMessage] {
        var result: [MIDIMessage] = []
        for byte in bytes {
            if byte == 0xff {
                running = nil; data.removeAll(); sysex = false; systemRemaining = 0
                result.append(MIDIMessage(status: byte, a: 0, b: 0)); continue
            }
            if byte >= 0xf8 { continue } // Real-time messages may occur anywhere.
            if byte >= 0x80 {
                data.removeAll(keepingCapacity: true)
                if byte >= 0xf0 {
                    running = nil
                    sysex = byte == 0xf0
                    systemRemaining = byte == 0xf2 ? 2 : ([0xf1,0xf3].contains(byte) ? 1 : 0)
                } else {
                    sysex = false; systemRemaining = 0; running = byte
                }
                continue
            }
            if sysex { continue }
            if systemRemaining > 0 { systemRemaining -= 1; continue }
            guard let status = running else { continue }
            data.append(byte)
            let length = [0xc0,0xd0].contains(status & 0xf0) ? 1 : 2
            if data.count == length {
                result.append(MIDIMessage(status: status, a: data[0], b: length == 2 ? data[1] : 0))
                data.removeAll(keepingCapacity: true)
            }
        }
        return result
    }
}

struct NoteID: Hashable { let source: Int; let channel: Int; let note: Int }
struct ChannelID: Hashable { let source: Int; let channel: Int }
enum PedalMode: Int { case space, local, ignore }

final class PianoEngine {
    var transpose = 0
    var channel: Int? = nil
    var tapMode = false
    var pedalMode = PedalMode.space
    var allowed: () -> Bool = { false }
    var emit: (PianoKey, Bool) -> Void = { _, _ in }
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
    private var active: [NoteID: (key: PianoKey, generation: Int)] = [:]
    private var owners: [UInt16: NoteID] = [:]
    private var pedals: Set<ChannelID> = []
    private var deferred: Set<NoteID> = []
    private var generation = 0
    private var spaceDown = false
    var heldCount: Int { active.count }
    let space = PianoKey(code: 49, shifted: false, label: "Space")

    func receive(_ message: MIDIMessage, source: Int) {
        if message.status == 0xff { panic(); return }
        guard channel == nil || channel == message.channel else { return }
        guard allowed() else { panic(); return }
        let id = NoteID(source: source, channel: message.channel, note: Int(message.a))
        let channelID = ChannelID(source: source, channel: message.channel)
        switch message.kind {
        case 0x90 where message.b > 0:
            guard let key = PianoMap.key(note: id.note, transpose: transpose) else { return }
            release(id)
            // One physical key cannot independently hold both e.g. 1 and Shift+1.
            if let previous = owners[key.code] { release(previous) }
            generation += 1
            let stamp = generation
            active[id] = (key, stamp); owners[key.code] = id
            emit(key, true)
            if tapMode {
                schedule(0.045) { [weak self] in
                    guard let self, self.active[id]?.generation == stamp else { return }
                    self.release(id)
                }
            }
        case 0x80, 0x90:
            if !tapMode {
                if pedalMode == .local && pedals.contains(channelID) { deferred.insert(id) }
                else { release(id) }
            }
        case 0xb0 where message.a == 64:
            guard pedalMode != .ignore else { return }
            if message.b >= 64 { pedals.insert(channelID) }
            else {
                pedals.remove(channelID)
                for note in Array(deferred) where note.source == source && note.channel == message.channel { release(note) }
            }
            if pedalMode == .space {
                let down = !pedals.isEmpty
                if down != spaceDown { spaceDown = down; emit(space, down) }
            }
        case 0xb0 where [120,121,123].contains(message.a):
            for note in Array(active.keys) where note.source == source && note.channel == message.channel { release(note) }
            pedals.remove(channelID)
            if spaceDown && pedals.isEmpty { spaceDown = false; emit(space, false) }
        default: break
        }
    }
    private func release(_ id: NoteID) {
        deferred.remove(id)
        if let note = active.removeValue(forKey: id) {
            owners.removeValue(forKey: note.key.code)
            emit(note.key, false)
        }
    }
    func panic() {
        for id in Array(active.keys) { release(id) }
        if spaceDown { emit(space, false) }
        spaceDown = false; pedals.removeAll(); deferred.removeAll()
    }
}
