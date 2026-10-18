import Foundation
import CoreMIDI

struct MIDISourceInfo: Equatable {
    let endpoint: MIDIEndpointRef
    let name: String
}

final class MIDIInput {
    private(set) var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var connected: Set<MIDIEndpointRef> = []
    private var parsers: [Int: MIDIParser] = [:]
    var onMessage: (MIDIMessage, Int) -> Void = { _, _ in }
    var onSetupChange: () -> Void = {}
    private(set) var error: String?
    init() {
        var status = MIDIClientCreateWithBlock("MITR" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onSetupChange() }
            }
        }
        guard status == noErr else { error = "CoreMIDI could not start (\(status))."; return }
        status = MIDIInputPortCreateWithBlock(client, "Piano input" as CFString, &port) { [weak self] list, connection in
            let source = Int(bitPattern: connection)
            let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
            let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
            var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
            var bytes: [UInt8] = []
            for _ in 0..<list.pointee.numPackets {
                let start = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                bytes.append(contentsOf: UnsafeBufferPointer(start: start, count: Int(packet.pointee.length)))
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.connected.contains(MIDIEndpointRef(truncatingIfNeeded: source)) else { return }
                var parser = self.parsers[source] ?? MIDIParser()
                let messages = parser.consume(bytes)
                self.parsers[source] = parser
                for message in messages { self.onMessage(message, source) }
            }
        }
        if status != noErr { error = "MIDI input could not open (\(status))." }
    }
    func sources() -> [MIDISourceInfo] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            var value: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value)
            return MIDISourceInfo(endpoint: endpoint, name: value?.takeRetainedValue() as String? ?? "MIDI input \(index + 1)")
        }
    }
    func connect(_ sources: [MIDISourceInfo]) {
        let wanted = Set(sources.map(\.endpoint))
        guard wanted != connected else { return }
        for endpoint in connected { MIDIPortDisconnectSource(port, endpoint) }
        connected.removeAll(); parsers.removeAll()
        guard port != 0 else { return }
        for source in sources {
            let status = MIDIPortConnectSource(port, source.endpoint, UnsafeMutableRawPointer(bitPattern: Int(source.endpoint)))
            if status == noErr { connected.insert(source.endpoint) }
            else { error = "Could not connect to \(source.name) (\(status))." }
        }
    }
    deinit {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }
}
