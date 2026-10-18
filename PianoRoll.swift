import AppKit
import SwiftUI

struct VisualNote {
    let pitch: Int
    let channel: Int
    let start: Double
    let end: Double
}

final class PianoTimeline {
    private struct Lane {
        var notes: [VisualNote] = []
        var latestEnd: [Double] = []
    }
    private var lanes = Array(repeating: Lane(), count: 61)
    let noteCount: Int
    init(song: MIDISong? = nil, channel: Int? = nil) {
        guard let song else { noteCount = 0; return }
        var starts: [Int: Double] = [:]
        var notes: [VisualNote] = []
        func append(_ pitch: Int, _ channel: Int, _ start: Double, _ end: Double) {
            guard (36...96).contains(pitch) else { return }
            notes.append(VisualNote(pitch: pitch, channel: channel, start: start, end: max(start + 0.015, end)))
        }
        for event in song.events {
            let message = event.message
            guard channel == nil || channel == message.channel else { continue }
            let id = message.channel * 128 + Int(message.a)
            if message.kind == 0x90 && message.b > 0 {
                if let previous = starts.updateValue(event.time, forKey: id) {
                    append(Int(message.a), message.channel, previous, event.time)
                }
            }
            else if message.kind == 0x80 || (message.kind == 0x90 && message.b == 0) {
                if let start = starts.removeValue(forKey: id) {
                    append(Int(message.a), message.channel, start, event.time)
                }
            } else if message.kind == 0xb0 && [120,121,123].contains(message.a) {
                for key in Array(starts.keys) where key / 128 == message.channel {
                    if let start = starts.removeValue(forKey: key) { append(key % 128, key / 128, start, event.time) }
                }
            }
        }
        for (id, start) in starts { append(id % 128, id / 128, start, song.duration) }
        for note in notes { lanes[note.pitch - 36].notes.append(note) }
        for index in lanes.indices {
            lanes[index].notes.sort { $0.start < $1.start }
            var end = 0.0
            for note in lanes[index].notes { end = max(end, note.end); lanes[index].latestEnd.append(end) }
        }
        noteCount = notes.count
    }
    func visible(from lower: Double, through upper: Double) -> [VisualNote] {
        var result: [VisualNote] = []
        for lane in lanes {
            var low = 0, high = lane.notes.count
            while low < high {
                let middle = (low + high) / 2
                if lane.latestEnd[middle] <= lower { low = middle + 1 } else { high = middle }
            }
            while low < lane.notes.count && lane.notes[low].start <= upper {
                if lane.notes[low].end > lower { result.append(lane.notes[low]) }
                low += 1
                if result.count >= 5000 { return result }
            }
        }
        return result
    }
}

struct PianoLane {
    let x: Double
    let width: Double
    let black: Bool
    static func forNote(_ note: Int) -> PianoLane? {
        guard (36...96).contains(note) else { return nil }
        let offset = note - 36, whites = [0,2,4,5,7,9,11]
        let pitch = offset % 12
        let index = (offset / 12) * 7 + whites.filter { $0 < pitch }.count
        let black = !whites.contains(pitch)
        return PianoLane(x: Double(index) - (black ? 0.32 : 0), width: black ? 0.64 : 1, black: black)
    }
}

struct PianoRoll: NSViewRepresentable {
    let timeline: PianoTimeline
    let position: Double
    let activeNotes: Set<Int>
    var compact = false
    var scroll: (Double) -> Void
    func makeNSView(context: Context) -> PianoRollSurface { PianoRollSurface() }
    func updateNSView(_ view: PianoRollSurface, context: Context) {
        view.timeline = timeline; view.position = position; view.activeNotes = activeNotes
        view.compact = compact; view.onScroll = scroll; view.needsDisplay = true
    }
}

final class PianoRollSurface: NSView {
    var timeline = PianoTimeline()
    var position = 0.0
    var activeNotes: Set<Int> = []
    var compact = false
    var onScroll: (Double) -> Void = { _ in }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) {
        let amount = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.012 : 0.3)
        onScroll(-amount)
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(calibratedWhite: 0.09, alpha: 1) : .white).setFill(); bounds.fill()
        let keyboardHeight: CGFloat = compact ? 44 : 62
        let strike = max(20, bounds.height - keyboardHeight)
        let unit = bounds.width / 36
        let seconds = compact ? 5.0 : 6.0
        let scale = Double(strike) / seconds
        let visible = timeline.visible(from: position, through: position + seconds)
        var lit = activeNotes
        for note in visible where note.start <= position && note.end > position { lit.insert(note.pitch) }
        for note in 36...96 {
            let lane = PianoLane.forNote(note)!
            guard !lane.black else { continue }
            let rect = NSRect(x: CGFloat(lane.x) * unit, y: 0, width: unit, height: strike)
            let shade: CGFloat = dark ? ((note % 12 == 0) ? 0.105 : 0.125) : ((note % 12 == 0) ? 0.963 : 0.985)
            NSColor(white: shade, alpha: 1).setFill(); rect.fill()
            NSColor(white: dark ? 0.19 : 0.91, alpha: 1).setStroke()
            let line = NSBezierPath(); line.move(to: rect.origin); line.line(to: NSPoint(x: rect.minX, y: strike)); line.stroke()
        }
        let firstSecond = Int(ceil(position))
        for second in firstSecond...max(firstSecond, Int(ceil(position + seconds))) {
            let y = strike - CGFloat(Double(second) - position) * CGFloat(scale)
            NSColor(white: dark ? 0.23 : 0.90, alpha: 1).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: y)); line.line(to: NSPoint(x: bounds.width, y: y)); line.stroke()
            if second % 2 == 0 {
                drawText(String(format: "%d:%02d", second / 60, second % 60),
                    rect: NSRect(x: 5, y: y - 15, width: 40, height: 14), color: .secondaryLabelColor, size: 9)
            }
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: strike)).addClip()
        for note in visible {
            let lane = PianoLane.forNote(note.pitch)!
            let y = strike - CGFloat(note.end - position) * CGFloat(scale)
            let height = max(5, CGFloat(note.end - note.start) * CGFloat(scale))
            let rect = NSRect(x: CGFloat(lane.x) * unit + 1.2, y: y,
                              width: max(2, CGFloat(lane.width) * unit - 2.4), height: height)
            let color = NSColor(calibratedHue: CGFloat(0.54 + Double(note.channel % 4) * 0.035),
                                saturation: dark ? 0.65 : (lane.black ? 0.59 : 0.40), brightness: 0.93, alpha: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            NSGradient(starting: color.withAlphaComponent(0.65), ending: color)?.draw(in: path, angle: 90)
            color.withAlphaComponent(0.9).setStroke(); path.lineWidth = 0.7; path.stroke()
            if rect.height >= 15 && rect.width >= 12 {
                drawText(PianoMap.key(note: note.pitch)!.label,
                         rect: NSRect(x: rect.minX, y: rect.maxY - 15, width: rect.width, height: 13),
                         color: NSColor(calibratedWhite: 0.12, alpha: 0.9), size: compact ? 9 : 10, centered: true)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        for black in [false, true] {
            for note in 36...96 {
                let lane = PianoLane.forNote(note)!
                guard lane.black == black else { continue }
                let height = black ? keyboardHeight * 0.61 : keyboardHeight
                let rect = NSRect(x: CGFloat(lane.x) * unit + 0.5, y: strike,
                                  width: CGFloat(lane.width) * unit - 1, height: height)
                let base = black ? NSColor(calibratedWhite: dark ? 0.04 : 0.12, alpha: 1)
                    : (dark ? NSColor(calibratedWhite: 0.22, alpha: 1) : .white)
                let color = lit.contains(note) ? NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.98, alpha: 1) : base
                color.setFill(); NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                NSColor(white: dark ? 0.31 : 0.82, alpha: 1).setStroke(); NSBezierPath(rect: rect).stroke()
                drawText(PianoMap.key(note: note)!.label,
                         rect: NSRect(x: rect.minX, y: rect.maxY - (compact ? 13 : 17), width: rect.width, height: 14),
                         color: lit.contains(note) ? .darkGray : (black ? .white : .secondaryLabelColor),
                         size: compact ? 8 : 10, centered: true)
            }
        }
        NSColor(calibratedRed: 0.39, green: 0.67, blue: 0.92, alpha: 1).setFill()
        NSRect(x: 0, y: strike - 1, width: bounds.width, height: 2).fill()
        if timeline.noteCount == 0 {
            drawText("Import a MIDI file", rect: NSRect(x: 0, y: strike / 2 - 10, width: bounds.width, height: 22),
                     color: .secondaryLabelColor, size: 14, centered: true)
        }
    }
    private func drawText(_ text: String, rect: NSRect, color: NSColor, size: CGFloat, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

// Mouse controls stay usable while Roblox retains keyboard focus.
final class MITROverlayPanel: NSPanel {
    override var canBecomeKey: Bool { NSApp.isActive }
    override var canBecomeMain: Bool { false }
}

final class OverlayHostingView: NSHostingView<OverlayView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SongVisualizer: View {
    @ObservedObject var model: PianoController
    var compact = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: model.fileState != .playing)) { _ in
            PianoRoll(timeline: model.visualTimeline, position: model.visualPosition,
                      activeNotes: model.fileLoaded ? [] : model.activeNotes, compact: compact,
                      scroll: model.scrollSong)
        }.clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            .help("Scroll up to rewind; scroll down to move forward.")
            .accessibilityLabel("MIDI piano roll. Scroll to seek through the song.")
    }
}

struct SongSeekBar: View {
    @ObservedObject var model: PianoController
    var body: some View {
        NativeSongSeekBar(value: model.filePosition, duration: model.fileDuration,
                          enabled: model.fileLoaded, seek: model.seekFile)
            .frame(height: 22)
    }
}

struct NativeSongSeekBar: NSViewRepresentable {
    let value: Double
    let duration: Double
    let enabled: Bool
    var seek: (Double) -> Void
    func makeNSView(context: Context) -> SongSeekSurface { SongSeekSurface() }
    func updateNSView(_ view: SongSeekSurface, context: Context) {
        view.value = value; view.duration = duration; view.enabled = enabled; view.onSeek = seek
        view.needsDisplay = true
    }
}

final class SongSeekSurface: NSView {
    var value = 0.0
    var duration = 0.0
    var enabled = false
    var onSeek: (Double) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Song position in seconds" }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityMinValue() -> Any? { 0.0 }
    override func accessibilityMaxValue() -> Any? { duration }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override func setAccessibilityValue(_ newValue: Any?) {
        if let number = newValue as? NSNumber { commit(number.doubleValue) }
        else if let text = newValue as? String, let number = Double(text) { commit(number) }
    }
    override func accessibilityPerformIncrement() -> Bool { commit(value + max(1, duration / 100)); return enabled }
    override func accessibilityPerformDecrement() -> Bool { commit(value - max(1, duration / 100)); return enabled }
    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }
    override func mouseUp(with event: NSEvent) { seek(event) }
    private func seek(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        commit(Double((point.x - 8) / max(1, bounds.width - 16)) * duration)
    }
    private func commit(_ seconds: Double) {
        guard enabled else { return }
        value = min(duration, max(0, seconds)); onSeek(value); needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let width = max(1, bounds.width - 16)
        let fraction = CGFloat(min(1, max(0, value / max(0.001, duration))))
        let y = bounds.midY
        NSColor(white: dark ? 0.28 : 0.91, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: y - 1.5, width: width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        (enabled ? (dark ? NSColor.white : NSColor.black) : NSColor.gray).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: y - 1.5, width: width * fraction, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        let knob = NSBezierPath(ovalIn: NSRect(x: 8 + width * fraction - 7, y: y - 7, width: 14, height: 14))
        NSColor.white.setFill(); knob.fill()
        NSColor(white: enabled ? 0.65 : 0.85, alpha: 1).setStroke(); knob.lineWidth = 0.8; knob.stroke()
    }
}

struct SongSpeedControl: View {
    @ObservedObject var model: PianoController
    var body: some View {
        HStack(spacing: 7) {
            Text("Speed").foregroundStyle(.secondary)
            Button("−") { model.changeSpeed(by: -10) }
                .disabled(model.speedPercent <= 10).accessibilityLabel("Decrease speed by 10 percent")
            Text("\(model.speedPercent)%").monospacedDigit().frame(width: 42)
            Button("+") { model.changeSpeed(by: 10) }
                .disabled(model.speedPercent >= 300).accessibilityLabel("Increase speed by 10 percent")
        }
    }
}

struct OverlayView: View {
    @ObservedObject var model: PianoController
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("MITR").font(.system(size: 18, weight: .semibold))
                Text(model.fileName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(model.filePlaying ? "Pause" : "Play", action: model.toggleFile).disabled(!model.fileLoaded)
                Button("Stop", action: model.stopFile).disabled(!model.fileLoaded)
            }
            SongVisualizer(model: model, compact: true).frame(minHeight: 130)
            HStack {
                Text(model.fileTime(model.filePosition)).monospacedDigit()
                SongSeekBar(model: model)
                Text(model.fileTime(model.fileDuration)).monospacedDigit()
            }.font(.system(size: 11))
            HStack {
                Toggle("3-second resume countdown", isOn: $model.resumeCountdown).toggleStyle(.checkbox)
                Toggle("Dark theme", isOn: $model.darkTheme).toggleStyle(.checkbox)
                Spacer()
                SongSpeedControl(model: model)
            }.font(.system(size: 11))
        }.padding(14).foregroundStyle(.primary).background(Theme.background)
            .preferredColorScheme(model.darkTheme ? .dark : .light)
    }
}
