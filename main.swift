import AppKit
import SwiftUI
import CoreGraphics
import CoreMIDI
import UniformTypeIdentifiers

private let robloxID = "com.roblox.RobloxPlayer"

final class KeyOutput {
    private var lastPID: pid_t?
    func send(_ key: PianoKey, down: Bool, testWindowFocused: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        let isTarget = front?.bundleIdentifier == robloxID || testWindowFocused
        guard !down || isTarget else { return }
        if down { lastPID = front?.processIdentifier }
        guard let pid = lastPID else { return }
        let source = CGEventSource(stateID: .privateState)
        func post(_ code: UInt16, _ down: Bool, _ flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            if isTarget { event.post(tap: .cghidEventTap) }
            else { event.postToPid(pid) } // Release only into the former target after a focus change.
        }
        if key.shifted { post(56, true, .maskShift) }
        post(key.code, down, key.shifted ? .maskShift : [])
        if key.shifted { post(56, false, []) }
    }
}

final class KeyCaptureView: NSView {
    var onKey: (String) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        onKey("↓  \(event.characters ?? "")    code \(event.keyCode)    \(event.modifierFlags.contains(.shift) ? "Shift" : "plain")")
    }
    override func keyUp(with event: NSEvent) { onKey("↑  code \(event.keyCode)") }
    override func flagsChanged(with event: NSEvent) {}
}

final class PianoController: NSObject, ObservableObject {
    @Published var sources: [MIDISourceInfo] = []
    @Published var selectedSource: UInt32 = 0 { didSet { connect() } }
    @Published var channel = 0 { didSet { resetOptions() } }
    @Published var transpose = 0 { didSet { resetOptions() } }
    @Published var tapMode = false { didSet { resetOptions() } }
    @Published var pedal = 0 { didSet { resetOptions() } }
    @Published var armed = false
    @Published var permission = false
    @Published var robloxFocused = false
    @Published var lastNote = "—"
    @Published var lastKey = "—"
    @Published var lastDetail = "Play a note on your MIDI keyboard."
    @Published var activeNotes: Set<Int> = []
    @Published var eventCount = 0
    @Published var midiError: String?
    @Published var fileName = "No file selected"
    @Published var fileError: String?
    @Published var fileLoaded = false
    @Published var fileState = MIDIFilePlayer.State.stopped
    @Published var filePosition = 0.0
    @Published var fileDuration = 0.0
    @Published var fileStatus = ""
    @Published var fileFitSummary = ""
    @Published var fileFitDetail = ""
    @Published var visualTimeline = PianoTimeline()
    @Published private var visualClock = ProcessInfo.processInfo.systemUptime
    @Published var humanize = false { didSet { resetFileTiming() } }
    @Published var humanizeMS = 8.0 { didSet { resetFileTiming() } }
    @Published var resumeCountdown = UserDefaults.standard.object(forKey: "resumeCountdown") as? Bool ?? false {
        didSet { UserDefaults.standard.set(resumeCountdown, forKey: "resumeCountdown") }
    }
    @Published private(set) var speedPercent = 100
    @Published var darkTheme = UserDefaults.standard.bool(forKey: "darkTheme") {
        didSet { UserDefaults.standard.set(darkTheme, forKey: "darkTheme"); applyTheme() }
    }
    private var originalSong: MIDISong?
    private var fittedSong: MIDISong?
    private let filePlayer = MIDIFilePlayer()
    private var playbackTimer: Timer?
    private var lastPlaybackUpdate = 0.0
    private let engine = PianoEngine()
    private let midi = MIDIInput()
    private let output = KeyOutput()
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var testWindow: NSWindow?
    private var overlayWindow: MITROverlayPanel?
    private var refreshInProgress = false
    var isTestFocused: Bool { testWindow?.isKeyWindow == true && NSApp.isActive }
    var deviceName: String {
        if sources.isEmpty { return "No keyboard connected" }
        if selectedSource == 0 { return sources.count == 1 ? sources[0].name : "\(sources.count) MIDI inputs" }
        return sources.first(where: { $0.endpoint == selectedSource })?.name ?? "Select an input"
    }
    override init() {
        super.init()
        applyTheme()
        engine.allowed = { [weak self] in
            guard let self else { return false }
            let frontIsRoblox = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == robloxID
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            return self.armed && CGPreflightPostEventAccess() && (frontIsRoblox || self.isTestFocused) && modifiers.isEmpty
        }
        engine.emit = { [weak self] key, down in
            guard let self else { return }
            self.output.send(key, down: down, testWindowFocused: self.isTestFocused)
        }
        filePlayer.emit = { [weak self] message in
            guard let self else { return }
            self.engine.transpose = 0 // File pitches already include transpose and range fitting.
            self.receive(message, source: -1)
        }
        filePlayer.release = { [weak self] in
            guard let self else { return }
            self.engine.panic(); self.engine.transpose = self.transpose; self.activeNotes.removeAll()
        }
        midi.onMessage = { [weak self] message, source in
            guard let self, self.filePlayer.state != .playing, self.filePlayer.state != .countdown else { return }
            self.receive(message, source: source)
        }
        midi.onSetupChange = { [weak self] in self?.refresh() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.panic()
            if self.filePlayer.state == .playing { self.filePlayer.pause(); self.updatePlayback() }
        }
        refresh(); tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        let playbackTimer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.filePlayer.advance(now: now, allowed: self.engine.allowed())
            if now - self.lastPlaybackUpdate >= 0.05 {
                self.lastPlaybackUpdate = now; self.updatePlayback()
            }
        }
        RunLoop.main.add(playbackTimer, forMode: .common); self.playbackTimer = playbackTimer
    }
    private func tick() {
        permission = CGPreflightPostEventAccess()
        robloxFocused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == robloxID
        if !permission { filePlayer.pause(); engine.panic(); armed = false }
        if !robloxFocused && !isTestFocused { engine.panic() }
    }
    func refresh() {
        let updated = midi.sources().filter { !$0.name.hasPrefix("MITR temporary self-test") }
        if updated != sources {
            engine.panic(); activeNotes.removeAll()
            refreshInProgress = true
            sources = updated
            if selectedSource != 0 && !updated.contains(where: { $0.endpoint == selectedSource }) { selectedSource = 0 }
            refreshInProgress = false
            connect()
        }
        midiError = midi.error
    }
    private func connect() {
        guard !refreshInProgress else { return }
        engine.panic(); activeNotes.removeAll()
        midi.connect(selectedSource == 0 ? sources : sources.filter { $0.endpoint == selectedSource })
        midiError = midi.error
    }
    private func resetOptions() {
        filePlayer.pause(); updatePlayback()
        engine.panic(); activeNotes.removeAll()
        engine.transpose = transpose
        engine.channel = channel == 0 ? nil : channel - 1
        engine.tapMode = tapMode
        engine.pedalMode = PedalMode(rawValue: pedal) ?? .space
        filePlayer.localSustain = pedal == 1 && !tapMode
        resetFileTiming()
    }
    private func receive(_ message: MIDIMessage, source: Int) {
        let noteTranspose = source == -1 ? 0 : transpose
        if message.status == 0xff { engine.receive(message, source: source); activeNotes.removeAll(); return }
        guard channel == 0 || message.channel == channel - 1 else { return }
        if message.kind == 0x90 && message.b > 0 {
            eventCount += 1
            let note = Int(message.a)
            let mapped = PianoMap.key(note: note, transpose: noteTranspose)
            lastNote = PianoMap.noteName(note)
            lastKey = mapped?.label ?? "—"
            lastDetail = mapped == nil ? "Outside C2–C7. Adjust transpose to bring this note into range."
                : "MIDI \(note)  ·  velocity \(message.b)  ·  channel \(message.channel + 1)\(armed ? "" : "  ·  monitor only")"
            if mapped != nil { activeNotes.insert(note + noteTranspose) }
        } else if message.kind == 0x80 || (message.kind == 0x90 && message.b == 0) {
            activeNotes.remove(Int(message.a) + noteTranspose)
        } else if message.kind == 0xb0 && [120,123].contains(message.a) { activeNotes.removeAll() }
        engine.receive(message, source: source)
    }
    func toggle() {
        permission = CGPreflightPostEventAccess()
        if !permission { requestPermission(); return }
        filePlayer.pause(); updatePlayback()
        engine.panic(); armed.toggle()
    }
    func panic() { stopFile(); engine.panic(); activeNotes.removeAll(); armed = false }
    func importFile() {
        filePlayer.pause(); updatePlayback()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["mid", "midi"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.prompt = "Import MIDI"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 * 1024 else { throw MIDIFileError.invalid("Choose a MIDI file smaller than 32 MB.") }
            let song = try MIDIFile.read(Data(contentsOf: url))
            originalSong = song; fileName = url.lastPathComponent
            fileLoaded = true; fileError = nil; resetFileTiming()
        } catch { fileError = error.localizedDescription }
    }
    private func resetFileTiming() {
        guard let originalSong else { return }
        let fit = originalSong.fittedToPiano(transpose: transpose, channel: channel == 0 ? nil : channel - 1)
        fittedSong = fit.song; fileFitSummary = fit.summary; fileFitDetail = fit.detail
        let prepared = humanize ? fit.song.humanized(milliseconds: humanizeMS) : fit.song
        visualTimeline = PianoTimeline(song: prepared, channel: channel == 0 ? nil : channel - 1)
        filePlayer.load(prepared); updatePlayback()
    }
    func toggleFile() {
        if filePlayer.state == .playing || filePlayer.state == .countdown {
            filePlayer.pause(); updatePlayback(); return
        }
        permission = CGPreflightPostEventAccess()
        guard permission else { requestPermission(); return }
        guard fittedSong != nil else { return }
        engine.panic(); activeNotes.removeAll(); armed = true
        filePlayer.play(now: ProcessInfo.processInfo.systemUptime,
                        resumeCountdown: resumeCountdown, allowed: engine.allowed())
        updatePlayback()
    }
    func stopFile() { filePlayer.stop(); updatePlayback() }
    func seekFile(to seconds: Double) {
        filePlayer.seek(to: seconds, now: ProcessInfo.processInfo.systemUptime, allowed: engine.allowed())
        updatePlayback()
    }
    func scrollSong(_ seconds: Double) { seekFile(to: filePlayer.position + seconds) }
    func changeSpeed(by amount: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        filePlayer.setSpeed(percent: speedPercent + amount, now: now, allowed: engine.allowed())
        speedPercent = filePlayer.speedPercent
        updatePlayback(); visualClock = now
    }
    var visualPosition: Double {
        guard fileState == .playing else { return filePosition }
        return min(fileDuration, filePosition + max(0, ProcessInfo.processInfo.systemUptime - visualClock) * filePlayer.playbackRate)
    }
    private func updatePlayback() {
        if fileState != filePlayer.state || filePosition != filePlayer.position {
            visualClock = ProcessInfo.processInfo.systemUptime
        }
        if fileState != filePlayer.state { fileState = filePlayer.state }
        if filePosition != filePlayer.position { filePosition = filePlayer.position }
        if fileDuration != filePlayer.duration { fileDuration = filePlayer.duration }
        let status: String
        switch filePlayer.state {
        case .stopped: status = fileLoaded ? "Ready" : ""
        case .countdown: status = "Starting in \(max(1, Int(ceil(filePlayer.countdown))))"
        case .playing: status = "Playing"
        case .paused: status = "Paused"
        case .finished: status = "Finished"
        }
        if fileStatus != status { fileStatus = status }
    }
    var filePlaying: Bool { fileState == .playing || fileState == .countdown }
    func fileTime(_ seconds: Double) -> String {
        let seconds = max(0, Int(seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    func requestPermission() {
        _ = CGRequestPostEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    private func applyTheme() {
        NSApp.appearance = NSAppearance(named: darkTheme ? .darkAqua : .aqua)
        for window in NSApp.windows {
            window.backgroundColor = Theme.windowColor
            if let capture = window.contentView as? KeyCaptureView {
                capture.layer?.backgroundColor = (darkTheme ? NSColor(calibratedWhite: 0.075, alpha: 1) : .white).cgColor
                for case let label as NSTextField in capture.subviews { label.textColor = .labelColor }
            }
            window.contentView?.needsDisplay = true
        }
    }
    func showOverlay() {
        if let overlayWindow {
            if NSApp.isActive { overlayWindow.makeKeyAndOrderFront(nil) }
            else { overlayWindow.orderFrontRegardless() }
            return
        }
        let panel = MITROverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 340),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "MITR Overlay"
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating; panel.isMovableByWindowBackground = true
        panel.backgroundColor = Theme.windowColor; panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 520, height: 270)
        panel.contentView = OverlayHostingView(rootView: OverlayView(model: self))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 700, y: frame.maxY - 380))
        }
        overlayWindow = panel
        if NSApp.isActive { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
    }
    func showTestWindow() {
        if let testWindow { testWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.title = "MITR Test"
        window.isReleasedWhenClosed = false
        let capture = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        capture.wantsLayer = true
        capture.layer?.backgroundColor = (darkTheme ? NSColor(calibratedWhite: 0.075, alpha: 1) : .white).cgColor
        let heading = NSTextField(labelWithString: "MITR Test")
        heading.font = .systemFont(ofSize: 25, weight: .semibold); heading.textColor = .labelColor
        heading.frame = NSRect(x: 30, y: 230, width: 500, height: 40); capture.addSubview(heading)
        let hint = NSTextField(wrappingLabelWithString: "Click Start, then play a MIDI note here.")
        hint.textColor = .gray; hint.frame = NSRect(x: 30, y: 155, width: 500, height: 65); capture.addSubview(hint)
        let label = NSTextField(labelWithString: "Waiting for a key…")
        label.font = .monospacedSystemFont(ofSize: 21, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 30, y: 75, width: 500, height: 45); capture.addSubview(label)
        capture.onKey = { label.stringValue = $0 }
        window.contentView = capture; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(capture); testWindow = window
    }
    func shutdown() { panic(); timer?.invalidate(); playbackTimer?.invalidate() }
}

enum Theme {
    static let windowColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.075, alpha: 1) : .white
    }
    static let background = Color(windowColor)
    static let card = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.11, alpha: 1) : .white
    })
    static let line = Color.primary.opacity(0.12)
    static let muted = Color.gray
    static let ink = Color.primary
    static let highlight = Color(red: 0.75, green: 0.85, blue: 1.0)
}

private struct Panel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

private struct PianoStrip: View {
    let active: Set<Int>
    private let whites = (36...96).filter { [0,2,4,5,7,9,11].contains($0 % 12) }
    private let blacks = (36...96).filter { [1,3,6,8,10].contains($0 % 12) }
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width / 36
            ZStack(alignment: .topLeading) {
                ForEach(Array(whites.enumerated()), id: \.element) { index, note in
                    VStack {
                        Spacer()
                        Text(PianoMap.key(note: note)!.label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.ink.opacity(0.65)).padding(.bottom, 9)
                    }
                    .frame(width: width - 2, height: 118)
                    .background(active.contains(note) ? Theme.highlight : .white, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line, lineWidth: 1))
                    .offset(x: CGFloat(index) * width)
                }
                ForEach(blacks, id: \.self) { note in
                    let position = whites.filter { $0 < note }.count
                    VStack {
                        Spacer()
                        Text(PianoMap.key(note: note)!.label)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(active.contains(note) ? Theme.ink : .white.opacity(0.8)).padding(.bottom, 8)
                    }
                    .frame(width: width * 0.61, height: 74)
                    .background(active.contains(note) ? Theme.highlight : Theme.ink, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: CGFloat(position) * width - width * 0.305 - 1)
                }
            }
        }.frame(height: 118)
            .animation(.easeOut(duration: 0.10), value: active)
    }
}

struct MainView: View {
    @ObservedObject var model: PianoController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MITR").font(.system(size: 29, weight: .semibold))
                Text("\(model.lastNote) → \(model.lastKey)")
                    .font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Overlay", action: model.showOverlay)
                Button(action: model.toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: model.armed ? "pause.fill" : "play.fill")
                        Text(model.armed ? "Stop" : "Start").fontWeight(.semibold)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 24).frame(height: 38)
                    .background(model.darkTheme ? Color(red: 0.25, green: 0.43, blue: 0.67) : Theme.ink,
                                in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
            SongVisualizer(model: model).frame(minHeight: 180, idealHeight: 270, maxHeight: .infinity)
            HStack(alignment: .top, spacing: 18) {
                Panel {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack {
                            Text("Input")
                            Spacer()
                            Button("Refresh", action: model.refresh)
                        }
                        Picker("Input", selection: $model.selectedSource) {
                            Text(model.sources.isEmpty ? "No MIDI keyboard" : "All MIDI inputs").tag(UInt32(0))
                            ForEach(model.sources, id: \.endpoint) { source in Text(source.name).tag(source.endpoint) }
                        }.labelsHidden()
                        HStack {
                            Text("Channel")
                            Spacer()
                            Picker("Channel", selection: $model.channel) {
                                Text("All").tag(0)
                                ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                            }.labelsHidden().frame(width: 110)
                        }
                        if let error = model.midiError { Text(error).foregroundStyle(.red) }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack {
                            Text("Transpose")
                            Spacer()
                            Button("−12") { model.transpose = max(-36, model.transpose - 12) }
                            Stepper(value: $model.transpose, in: -36...36) {
                                Text("\(model.transpose > 0 ? "+" : "")\(model.transpose)").monospacedDigit().frame(width: 28)
                            }.frame(width: 88)
                            Button("+12") { model.transpose = min(36, model.transpose + 12) }
                        }
                        HStack {
                            Text("Notes"); Spacer()
                            Picker("Notes", selection: $model.tapMode) {
                                Text("Hold").tag(false); Text("Tap").tag(true)
                            }.labelsHidden().frame(width: 160)
                        }
                        HStack {
                            Text("Pedal"); Spacer()
                            Picker("Pedal", selection: $model.pedal) {
                                Text("Space").tag(0); Text("Sustain").tag(1); Text("Off").tag(2)
                            }.labelsHidden().frame(width: 160)
                        }
                    }
                }
            }.font(.system(size: 12))
            Panel {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 14) {
                        Text("MIDI file").font(.system(size: 15, weight: .semibold))
                        Text(model.fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Button("Import…", action: model.importFile).accessibilityLabel("Import MIDI file")
                    }
                    HStack(spacing: 14) {
                        Button(action: model.toggleFile) {
                            Label(model.filePlaying ? "Pause" : (model.fileState == .paused ? "Resume" : "Play"),
                                  systemImage: model.filePlaying ? "pause.fill" : "play.fill")
                                .frame(width: 76)
                        }.disabled(!model.fileLoaded)
                        Button("Stop", action: model.stopFile).disabled(!model.fileLoaded).accessibilityLabel("Stop MIDI file")
                        SongSeekBar(model: model)
                        Text("\(model.fileTime(model.filePosition)) / \(model.fileTime(model.fileDuration))")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Text(model.fileStatus).frame(width: 88, alignment: .trailing)
                    }
                    HStack(spacing: 14) {
                        Toggle("Humanize", isOn: $model.humanize).toggleStyle(.switch)
                        Slider(value: $model.humanizeMS, in: 1...20, step: 1)
                            .frame(width: 150).disabled(!model.humanize)
                            .accessibilityLabel("Timing variation in milliseconds")
                        Text("\(Int(model.humanizeMS)) ms").monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Text(model.fileFitSummary).foregroundStyle(.secondary).help(model.fileFitDetail)
                    }
                    HStack {
                        Toggle("3-second resume countdown", isOn: $model.resumeCountdown).toggleStyle(.checkbox)
                        Toggle("Dark theme", isOn: $model.darkTheme).toggleStyle(.checkbox)
                        Spacer()
                        SongSpeedControl(model: model)
                    }
                    if let error = model.fileError { Text(error).foregroundStyle(.red) }
                }.font(.system(size: 12))
            }
            HStack(spacing: 12) {
                Button("Test", action: model.showTestWindow)
                Button("Release all", action: model.panic)
                Spacer()
            }.font(.system(size: 12))
        }
        .padding(22).frame(minWidth: 850, minHeight: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Theme.ink).background(Theme.background)
        .preferredColorScheme(model.darkTheme ? .dark : .light)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: PianoController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = PianoController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 800),
                          styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "MITR"
        window.minSize = NSSize(width: 870, height: 750)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.windowColor
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil)
        let menu = NSMenu()
        let appMenu = NSMenu(); let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
        appMenu.addItem(withTitle: "About MITR", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MITR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTests())
} else if CommandLine.arguments.contains("--list-midi") {
    let input = MIDIInput()
    if let error = input.error { print(error); exit(1) }
    let sources = input.sources()
    for source in sources { print("\(source.endpoint)\t\(source.name)") }
    if sources.isEmpty { print("No MIDI input devices connected.") }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
