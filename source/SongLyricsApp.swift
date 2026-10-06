// The window: drop songs, get their sung words with timing, check and fix them, save.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - App

@main
struct SongLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LyricsModel.shared
    @StateObject private var player = Player.shared

    var body: some Scene {
        Window("\(AppInfo.name) \(AppInfo.version)", id: "main") {
            ContentView().environmentObject(model).environmentObject(player)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Songs…") { model.chooseFiles() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Lyrics") { model.saveSelected() }
                    .keyboardShortcut("s")
                    .disabled(!(model.selectedSong?.dirty ?? false))
            }
            CommandMenu("Playback") {
                // The space bar is handled by the app itself (a menu shortcut would steal it from the text
                // fields), so this item only shows it.
                Button(player.isPlaying ? "Pause   Space" : "Play   Space") { player.toggle() }
                    .disabled(player.url == nil)
                Button("Back 5 Seconds") { player.seek(by: -5) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(player.url == nil)
                Button("Forward 5 Seconds") { player.seek(by: 5) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(player.url == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Songs dropped on the Dock icon, or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) { LyricsModel.shared.add(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = LyricsModel.shared.songs.filter(\.dirty)
        guard !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1 ? "Save your changes to “\(unsaved[0].name)”?"
                                               : "Save your changes to \(unsaved.count) songs?"
        alert.informativeText = "The lyrics were edited and not saved yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: LyricsModel.shared.saveAll(); return .terminateNow
        case .alertSecondButtonReturn: return .terminateCancel
        default: return .terminateNow
        }
    }

    /// A transcription still running is stopped with the app (its own process only).
    func applicationWillTerminate(_ notification: Notification) { LyricsModel.shared.stopEverything() }

    /// Space bar = play / pause, except while typing in a text field.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            guard event.keyCode == 49, plain, !(event.window is NSPanel),
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  Player.shared.url != nil
            else { return event }
            Player.shared.toggle()
            return nil
        }
    }
}

// MARK: - Model

enum SongState: Equatable {
    case waiting
    case working(String)          // what lyrics.py is doing now ("Listening…", "Isolating the voice…")
    case done
    case failed(String)
    case stopped
}

struct Song: Identifiable {
    let id = UUID()
    let url: URL
    var folder: URL                       // where its lyrics are written
    var state: SongState = .waiting
    var lines: [LyricLine] = []
    var tags: [String] = []
    var lrcURL: URL?
    var language: String?
    var duration: Double = 0
    var dirty = false
    var note = ""                         // a remark shown under the title (voice isolation skipped, ...)
    var videoURL: URL?
    var bpm: Double?                      // measured tempo, shown above the lyrics

    var name: String { url.deletingPathExtension().lastPathComponent }
    var isBusy: Bool { if case .working = state { return true } else { return false } }
}

/// The frame of a lyric video. The short side is always 1080 pixels (the long side of 16:9 and 9:16 is 1920).
enum ClipFormat: String, CaseIterable, Identifiable {
    case r16x9 = "16:9", r3x2 = "3:2", r4x3 = "4:3", r5x4 = "5:4", square = "1:1"
    case r4x5 = "4:5", r3x4 = "3:4", r2x3 = "2:3", r9x16 = "9:16"
    var id: String { rawValue }

    static let horizontal: [ClipFormat] = [.r16x9, .r3x2, .r4x3, .r5x4, .square]
    static let vertical: [ClipFormat] = [.r9x16, .r2x3, .r3x4, .r4x5]

    var ratio: (w: Double, h: Double) {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        return (parts[0], parts[1])
    }
    var pixels: (w: Int, h: Int) {
        let (w, h) = ratio
        func even(_ x: Double) -> Int { Int((x / 2).rounded()) * 2 }
        return w >= h ? (even(1080 * w / h), 1080) : (1080, even(1080 * h / w))
    }
    var size: String { "\(pixels.w)x\(pixels.h)" }
    var tag: String { rawValue.replacingOccurrences(of: ":", with: "x") }
    var help: String {
        let p = "\(pixels.w) × \(pixels.h)"
        switch self {
        case .r16x9: return "Landscape 16:9, \(p): YouTube, television, iMovie."
        case .r3x2: return "Landscape 3:2, \(p): the shape of most photo cameras."
        case .r4x3: return "Landscape 4:3, \(p): old television, iPad."
        case .r5x4: return "Landscape 5:4, \(p): almost square."
        case .square: return "Square, \(p): Instagram posts."
        case .r4x5: return "Portrait 4:5, \(p): the Instagram feed."
        case .r3x4: return "Portrait 3:4, \(p)."
        case .r2x3: return "Portrait 2:3, \(p): a photo held upright."
        case .r9x16: return "Vertical 9:16, \(p): TikTok, Reels, Shorts. The words sit higher, clear of the apps’ buttons."
        }
    }
}

enum OutputPlace: String, CaseIterable, Identifiable {
    case movies = "Movies › Lyrics"
    case beside = "Next to each song"
    case custom = "Other folder"
    var id: String { rawValue }
}

let languages: [(code: String, name: String)] = [
    ("auto", "Detect"), ("en", "English"), ("fr", "French"), ("es", "Spanish"), ("de", "German"),
    ("it", "Italian"), ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
]

final class LyricsModel: ObservableObject {
    static let shared = LyricsModel()

    @Published var songs: [Song] = []
    @Published var selection: Song.ID? { didSet { if selection != oldValue { openSelectedInPlayer() } } }
    @Published var dropTargeted = false
    @Published var message = ""
    @Published var elapsed = 0                      // seconds spent on the current job
    @Published private(set) var videoJob: String?   // "Making the QuickTime video…" while a video is made
    @Published private(set) var videoProgress: Double?

    // The lyric video's settings, remembered too.
    @Published var clipFormat: ClipFormat = .r16x9 { didSet { remember() } }
    @Published var clipCrop = true { didSet { remember() } }
    @Published var kenBurns = false { didSet { remember() } }
    @Published var kenBurnsAmount = 0.3 { didSet { remember() } }
    @Published var cutOnBeat = false { didSet { remember() } }
    @Published var clipWords = true { didSet { remember() } }
    @Published var clipOriginalSound = true { didSet { remember() } }
    @Published var clipPick = false { didSet { remember() } }
    @Published var clipPickCount = 50 { didSet { remember() } }
    @Published var clipShuffle = false { didSet { remember() } }
    @Published var clipCount = 1 { didSet { remember() } }
    @Published var clipAlsoMP4 = true { didSet { remember() } }   // an .mp4 beside a .mov, for Discord and the web
    @Published var kenBurnsShare = 20.0 { didSet { remember() } }  // % of the pictures that move
    @Published var crossfades = false { didSet { remember() } }
    @Published var crossfadeShare = 10.0 { didSet { remember() } } // % of the cuts that dissolve       // several videos, each with its own random draw
    @Published var clipPictures: [URL] = []                      // chosen, waiting for "Make"
    @Published private(set) var clipBatch: (done: Int, total: Int)?

    // Remembered between launches.
    @Published var language = "auto" { didSet { remember() } }
    @Published var isolateVoice = false { didSet { remember() } }
    @Published var place: OutputPlace = .movies { didSet { remember() } }
    @Published var customFolder: URL? { didSet { remember() } }
    @Published var textStyle: TextStyle = .withTimes { didSet { remember() } }

    private var current: ScriptRun?
    private var currentID: Song.ID?
    private var clock: Timer?
    private var isRestoring = false

    var selectedSong: Song? { songs.first { $0.id == selection } }
    var isWorking: Bool { current != nil }
    var waitingCount: Int { songs.filter { $0.state == .waiting }.count }

    init() {
        isRestoring = true
        defer { isRestoring = false }
        let d = UserDefaults.standard
        language = d.string(forKey: "language") ?? "auto"
        isolateVoice = d.bool(forKey: "isolateVoice")
        place = d.string(forKey: "place").flatMap(OutputPlace.init) ?? .movies
        customFolder = d.string(forKey: "customFolder").map { URL(fileURLWithPath: $0) }
        textStyle = d.string(forKey: "textStyle").flatMap(TextStyle.init) ?? .withTimes
        clipFormat = d.string(forKey: "clipFormat").flatMap(ClipFormat.init) ?? .r16x9
        clipCrop = d.object(forKey: "clipCrop") as? Bool ?? true
        kenBurns = d.bool(forKey: "kenBurns")
        kenBurnsAmount = d.object(forKey: "kenBurnsAmount") as? Double ?? 0.3
        cutOnBeat = d.bool(forKey: "cutOnBeat")
        clipWords = d.object(forKey: "clipWords") as? Bool ?? true
        clipOriginalSound = d.object(forKey: "clipOriginalSound") as? Bool ?? true
        clipPick = d.bool(forKey: "clipPick")
        clipPickCount = d.object(forKey: "clipPickCount") as? Int ?? 50
        clipShuffle = d.bool(forKey: "clipShuffle")
        clipCount = d.object(forKey: "clipCount") as? Int ?? 1
        clipAlsoMP4 = d.object(forKey: "clipAlsoMP4") as? Bool ?? true
        kenBurnsShare = d.object(forKey: "kenBurnsShare") as? Double ?? 20
        crossfades = d.bool(forKey: "crossfades")
        crossfadeShare = d.object(forKey: "crossfadeShare") as? Double ?? 10
        if place == .custom && customFolder == nil { place = .movies }
    }

    private func remember() {
        if isRestoring { return }
        let d = UserDefaults.standard
        d.set(language, forKey: "language")
        d.set(isolateVoice, forKey: "isolateVoice")
        d.set(place.rawValue, forKey: "place")
        d.set(customFolder?.path, forKey: "customFolder")
        d.set(textStyle.rawValue, forKey: "textStyle")
        d.set(clipFormat.rawValue, forKey: "clipFormat")
        d.set(clipCrop, forKey: "clipCrop")
        d.set(kenBurns, forKey: "kenBurns")
        d.set(kenBurnsAmount, forKey: "kenBurnsAmount")
        d.set(cutOnBeat, forKey: "cutOnBeat")
        d.set(clipWords, forKey: "clipWords")
        d.set(clipOriginalSound, forKey: "clipOriginalSound")
        d.set(clipPick, forKey: "clipPick")
        d.set(clipPickCount, forKey: "clipPickCount")
        d.set(clipShuffle, forKey: "clipShuffle")
        d.set(clipCount, forKey: "clipCount")
        d.set(clipAlsoMP4, forKey: "clipAlsoMP4")
        d.set(kenBurnsShare, forKey: "kenBurnsShare")
        d.set(crossfades, forKey: "crossfades")
        d.set(crossfadeShare, forKey: "crossfadeShare")
    }

    // MARK: Where the lyrics go

    /// The song's own folder only when chosen, and never inside a protected folder (Paths.protectedFolders).
    func outputFolder(for song: URL) -> (URL, String) {
        let stem = song.deletingPathExtension().lastPathComponent
        let inMovies = Paths.defaultOutput.appendingPathComponent(stem)
        switch place {
        case .movies:
            return (inMovies, "")
        case .custom:
            return ((customFolder ?? Paths.defaultOutput).appendingPathComponent(stem), "")
        case .beside:
            let path = song.path
            if Paths.protectedFolders.contains(where: { !$0.isEmpty && path.contains($0) }) {
                return (inMovies, "The song’s own folder is protected, so its lyrics went to Movies › Lyrics instead.")
            }
            return (song.deletingLastPathComponent(), "")
        }
    }

    func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder for the lyrics (each song gets its own folder inside)"
        if panel.runModal() == .OK, let url = panel.url { customFolder = url; place = .custom }
        else if customFolder == nil { place = .movies }
    }

    func revealOutputRoot() {
        let root: URL
        switch place {
        case .movies: root = Paths.defaultOutput
        case .custom: root = customFolder ?? Paths.defaultOutput
        case .beside: root = selectedSong?.url.deletingLastPathComponent() ?? Paths.defaultOutput
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    // MARK: Adding songs

    static let audioExtensions: Set<String> = ["wav", "mp3", "flac", "m4a", "aif", "aiff", "aac", "ogg", "caf"]

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose the songs to transcribe (or a folder of songs)"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Adds songs (a folder gives the songs inside it, sub-folders included) and starts on them at once.
    /// A song whose lyrics already exist is simply opened: nothing is transcribed again unless asked.
    func add(_ dropped: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [URL] = []
            for url in dropped {
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
                if isFolder.boolValue {
                    let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    while let item = walker?.nextObject() as? URL {
                        if LyricsModel.isSong(item) { files.append(item) }
                    }
                } else if LyricsModel.isSong(url) {
                    files.append(url)
                }
            }
            files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            DispatchQueue.main.async { self.enqueue(files) }
        }
    }

    /// Audio files, but not the vocal stems lyrics.py leaves in its output folders.
    static func isSong(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.contains(".vocals.")
    }

    private func enqueue(_ files: [URL]) {
        guard !files.isEmpty else {
            message = "Nothing to open: drop songs (WAV, MP3, FLAC, M4A, AIFF) or a folder of songs."
            return
        }
        message = ""
        var firstNew: Song.ID?
        for url in files {
            if let existing = songs.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                firstNew = firstNew ?? existing.id
                continue
            }
            let (folder, note) = outputFolder(for: url)
            var song = Song(url: url, folder: folder)
            song.note = note
            song.duration = LyricsModel.duration(of: url)
            let lrc = folder.appendingPathComponent(song.name + ".lrc")
            if FileManager.default.fileExists(atPath: lrc.path), let read = try? LyricsFiles.readLRC(lrc) {
                song.lrcURL = lrc
                song.lines = read.lines
                song.tags = read.tags
                song.state = .done
                song.note = "Opened the lyrics made earlier. “Transcribe Again” starts over; your edits are kept apart."
            }
            songs.append(song)
            if song.state == .done { detectTempo(song.id) }
            firstNew = firstNew ?? song.id
        }
        if selection == nil || !(selectedSong?.isBusy ?? false) { selection = firstNew }
        runNext()
    }

    static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func remove(_ id: Song.ID) {
        guard let song = songs.first(where: { $0.id == id }), !song.isBusy else { return }
        if song.dirty {
            let alert = NSAlert()
            alert.messageText = "Remove “\(song.name)” from the list without saving your changes?"
            alert.informativeText = "Its files stay where they are; only the changes made since the last save are lost."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        songs.removeAll { $0.id == id }
        if selection == id { selection = songs.first?.id }
    }

    func clearFinished() {
        let keep = songs.filter { $0.state == .waiting || $0.isBusy || $0.dirty }
        songs = keep
        if !songs.contains(where: { $0.id == selection }) { selection = songs.first?.id }
    }

    // MARK: Transcribing, one song after the other

    private func runNext() {
        guard current == nil, videoJob == nil, let index = songs.firstIndex(where: { $0.state == .waiting }) else { return }
        let song = songs[index]
        var args = ["transcribe", song.url.path, "--out", song.folder.path, "--lang", language]

        // The vocal separation is the heavy part: never next to a render (the Mac crashed once, 5 Oct 2026).
        if isolateVoice {
            let busy = GPUNeighbours.busy()
            if !Paths.canIsolateVoice {
                songs[index].note = "Voice isolation is not available right now: the whole mix was transcribed."
            } else if busy.contains("a YuE render") {
                songs[index].note = "Voice isolation was skipped because another render was using the graphics memory: the whole mix was transcribed."
            } else {
                args.append("--stems")
            }
        }

        songs[index].state = .working("Starting…")
        currentID = song.id
        startClock()
        do {
            current = try ScriptRun(arguments: args, onLine: { [weak self] line in
                DispatchQueue.main.async { self?.scriptSaid(line, about: song.id) }
            }, onExit: { [weak self] status, errors in
                DispatchQueue.main.async { self?.scriptEnded(song.id, status: status, errors: errors) }
            })
        } catch {
            current = nil
            currentID = nil
            stopClock()
            songs[index].state = .failed(error.localizedDescription)
            runNext()
        }
    }

    private var lastWritten: [Song.ID: URL] = [:]

    private func scriptSaid(_ line: String, about id: Song.ID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("isolating the voice") { songs[i].state = .working("Isolating the voice…") }
        else if text.hasPrefix("transcribing") { songs[i].state = .working("Listening…") }
        else if text.hasPrefix("language:") {
            songs[i].language = text.dropFirst(9).split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) }
        } else if text.hasPrefix("Written:"), lastWritten[id] == nil {
            lastWritten[id] = URL(fileURLWithPath: text.dropFirst(8).trimmingCharacters(in: .whitespaces))
        } else if text.contains("was edited since the last transcription") {
            songs[i].note = "Your edited lyrics were kept. This new transcription is in separate files, \(songs[i].name).whisper.lrc, .srt and .txt."
        } else if text.hasPrefix("(") && text.hasSuffix(")") {
            songs[i].note = String(text.dropFirst().dropLast())     // lyrics.py's own remarks, e.g. no separator
        }
    }

    private func scriptEnded(_ id: Song.ID, status: Int32, errors: String) {
        let stopped = current?.wasStopped ?? false
        current = nil
        currentID = nil
        stopClock()
        if let i = songs.firstIndex(where: { $0.id == id }) {
            if stopped {
                songs[i].state = .stopped
            } else if status == 0, let lrc = lastWritten[id] ?? Optional(songs[i].folder.appendingPathComponent(songs[i].name + ".lrc")),
                      let read = try? LyricsFiles.readLRC(lrc) {
                songs[i].lrcURL = lrc
                songs[i].lines = read.lines
                songs[i].tags = read.tags
                songs[i].dirty = false
                songs[i].state = .done
                if songs[i].duration == 0 { songs[i].duration = LyricsModel.duration(of: songs[i].url) }
                // the .txt follows the app's choice (the .lrc is left exactly as lyrics.py wrote it)
                _ = try? LyricsFiles.writeText(folder: lrc.deletingLastPathComponent(),
                                               name: lrc.deletingPathExtension().lastPathComponent, lines: read.lines, style: textStyle)
                if read.lines.isEmpty { songs[i].note = "Whisper heard no sung words in this song." }
                detectTempo(id)
                if selection == id { openSelectedInPlayer() }
            } else {
                let lines = errors.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                songs[i].state = .failed(lines.suffix(3).joined(separator: " ").isEmpty ? "lyrics.py stopped (code \(status))."
                                                                                       : lines.suffix(3).joined(separator: " "))
            }
        }
        lastWritten[id] = nil
        runNext()
    }

    /// Stops the song being transcribed; the ones still waiting are left out too.
    func stopEverything() {
        clipBatch = nil
        for i in songs.indices where songs[i].state == .waiting { songs[i].state = .stopped }
        current?.stop()
    }

    func transcribeAgain(_ id: Song.ID) {
        guard let i = songs.firstIndex(where: { $0.id == id }), !songs[i].isBusy else { return }
        if songs[i].dirty { saveSong(at: i) }        // the edit is saved first, so lyrics.py keeps it apart
        let (folder, note) = outputFolder(for: songs[i].url)
        songs[i].folder = folder
        songs[i].note = note
        songs[i].state = .waiting
        runNext()
    }

    private func startClock() {
        elapsed = 0
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.elapsed += 1 }
    }

    private func stopClock() { clock?.invalidate(); clock = nil }

    // MARK: Editing

    func binding(for line: LyricLine.ID, in song: Song.ID) -> Binding<LyricLine>? {
        guard let s = songs.firstIndex(where: { $0.id == song }),
              songs[s].lines.contains(where: { $0.id == line }) else { return nil }
        return Binding(
            get: { [weak self] in
                guard let self, let s = self.songs.firstIndex(where: { $0.id == song }),
                      let l = self.songs[s].lines.firstIndex(where: { $0.id == line }) else { return LyricLine(time: 0, text: "") }
                return self.songs[s].lines[l]
            },
            set: { [weak self] value in
                guard let self, let s = self.songs.firstIndex(where: { $0.id == song }),
                      let l = self.songs[s].lines.firstIndex(where: { $0.id == line }),
                      self.songs[s].lines[l] != value else { return }
                let moved = self.songs[s].lines[l].time != value.time
                self.songs[s].lines[l] = value
                if moved { self.songs[s].lines.sort { $0.time < $1.time } }
                self.songs[s].dirty = true
            })
    }

    func insertLine(after line: LyricLine.ID, in song: Song.ID) {
        guard let s = songs.firstIndex(where: { $0.id == song }),
              let l = songs[s].lines.firstIndex(where: { $0.id == line }) else { return }
        let here = songs[s].lines[l].time
        let next = l + 1 < songs[s].lines.count ? songs[s].lines[l + 1].time : max(here + 4, songs[s].duration)
        songs[s].lines.insert(LyricLine(time: ((here + next) / 2 * 100).rounded() / 100, text: "…"), at: l + 1)
        songs[s].dirty = true
    }

    func addFirstLine(to song: Song.ID) {
        guard let s = songs.firstIndex(where: { $0.id == song }) else { return }
        songs[s].lines.insert(LyricLine(time: (Player.shared.now * 100).rounded() / 100, text: "…"), at: 0)
        songs[s].lines.sort { $0.time < $1.time }
        songs[s].dirty = true
    }

    func deleteLine(_ line: LyricLine.ID, in song: Song.ID) {
        guard let s = songs.firstIndex(where: { $0.id == song }) else { return }
        songs[s].lines.removeAll { $0.id == line }
        songs[s].dirty = true
    }

    // MARK: Saving

    func saveSelected() {
        guard let i = songs.firstIndex(where: { $0.id == selection }) else { return }
        saveSong(at: i)
    }

    func saveAll() { for i in songs.indices where songs[i].dirty { saveSong(at: i) } }

    private func saveSong(at i: Int) {
        let song = songs[i]
        let lrc = song.lrcURL ?? song.folder.appendingPathComponent(song.name + ".lrc")
        do {
            try FileManager.default.createDirectory(at: lrc.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LyricsFiles.writeAll(lrc: lrc, tags: song.tags, lines: song.lines,
                                     total: song.duration > 0 ? song.duration : (song.lines.last?.time ?? 0) + 5,
                                     textStyle: textStyle)
            songs[i].lrcURL = lrc
            songs[i].dirty = false
            message = ""
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    func reveal(_ song: Song) {
        if let url = song.videoURL ?? song.lrcURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(song.folder) }
    }

    func openInTextEdit(_ song: Song) {
        guard let lrc = song.lrcURL else { return }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([lrc], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    func copyLyrics(_ song: Song, withTimes: Bool) {
        let text = song.lines.map { withTimes ? "[\(LyricsFiles.lrcStamp($0.time))]\($0.text)" : $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Videos (lyrics.py quicktime / overlay, and the app's own clip.py for lyric videos)

    enum VideoKind { case quicktime, overlay, lyricVideo }

    /// Lyric videos: one picture or many. Several pictures follow the order of their file names.
    func chooseClipPictures() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose one picture, several, or a folder. They are shown in the order of their file names (1-, 2-, …)."
        guard panel.runModal() == .OK else { return }
        var pictures: [URL] = []
        for url in panel.urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                           options: [.skipsHiddenFiles])) ?? []
                pictures += inside.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image)) ?? false }
            } else {
                pictures.append(url)
            }
        }
        // the same file chosen twice (on its own and inside its folder) counts once
        var seen = Set<String>()
        pictures = pictures.filter { seen.insert($0.standardizedFileURL.path).inserted }
        pictures.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if !pictures.isEmpty { clipPictures = pictures }
    }

    /// True when each video draws its pictures at random, so that several videos differ.
    var clipIsRandom: Bool {
        (clipPick && clipPickCount < clipPictures.count) || clipShuffle
            || (kenBurns && kenBurnsShare < 100) || (crossfades && crossfadeShare > 0 && crossfadeShare < 100)
    }

    /// Makes one lyric video, or several one after the other when the pictures are drawn at random.
    func makeLyricVideos(for id: Song.ID) {
        guard !clipPictures.isEmpty, current == nil, videoJob == nil else { return }
        clipBatch = (0, clipIsRandom ? max(1, min(clipCount, 50)) : 1)
        makeVideo(.lyricVideo, for: id, pictures: clipPictures)
    }

    /// A file name that is not taken yet: name.mp4, name_2.mp4, ...
    static func freeURL(_ folder: URL, _ name: String, _ ext: String) -> URL {
        var url = folder.appendingPathComponent(name + "." + ext)
        var n = 2
        func taken(_ u: URL) -> Bool {          // the video may come out as .mov (original sound): check both
            ["mp4", "mov"].contains { FileManager.default.fileExists(atPath: u.deletingPathExtension().appendingPathExtension($0).path) }
        }
        while taken(url) {
            url = folder.appendingPathComponent("\(name)_\(n).\(ext)"); n += 1
        }
        return url
    }

    func makeVideo(_ kind: VideoKind, for id: Song.ID, pictures: [URL] = []) {
        guard current == nil, videoJob == nil, let i = songs.firstIndex(where: { $0.id == id }), songs[i].state == .done else { return }
        if songs[i].dirty { saveSong(at: i) }
        guard let lrc = songs[i].lrcURL else { return }
        let song = songs[i]
        var args: [String]
        var script: URL?
        switch kind {
        case .quicktime:
            args = ["quicktime", song.url.path, lrc.path, "--out", song.folder.path]; videoJob = "Making the QuickTime video…"
        case .overlay:
            args = ["overlay", song.url.path, lrc.path, "--out", song.folder.path]; videoJob = "Making the iMovie overlay…"
        case .lyricVideo:
            guard let clip = Paths.clipScript else { songs[i].note = "The lyric video maker is missing from the app."; return }
            script = clip
            let out = LyricsModel.freeURL(song.folder, "\(song.name)_lyric_video_\(clipFormat.tag)", "mp4")
            let lyrics = song.lines.isEmpty ? "-" : lrc.path          // an instrumental: pictures only
            args = ["video", song.url.path, lyrics, "--images"] + pictures.map(\.path)
                + ["--size", clipFormat.size, "--fit", clipCrop ? "fill" : "fit",
                   "--kenburns", kenBurns ? String(format: "%.2f", kenBurnsAmount) : "0", "--out", out.path]
            if cutOnBeat && song.bpm != nil { args.append("--beats") }
            if !clipWords { args.append("--no-words") }
            if clipOriginalSound { args += ["--audio", "original"] }
            if clipOriginalSound && clipAlsoMP4 { args.append("--also-mp4") }
            if kenBurns { args += ["--kb-share", String(format: "%.2f", kenBurnsShare / 100)] }
            if crossfades { args += ["--fades", String(format: "%.2f", crossfadeShare / 100)] }
            // a new seed for every video: which pictures are drawn, which ones move, which cuts dissolve.
            // It is written in the .txt beside the video, so a video that pleases can be made again.
            args += ["--seed", String(Int.random(in: 1...999_999))]
            if (clipPick && clipPickCount < pictures.count) || clipShuffle {
                if clipPick && clipPickCount < pictures.count { args += ["--pick", String(max(1, clipPickCount))] }
                if clipShuffle { args.append("--shuffle") }
            }
            let used = clipPick ? min(max(1, clipPickCount), pictures.count) : pictures.count
            let which = (clipBatch?.total ?? 1) > 1 ? "video \((clipBatch?.done ?? 0) + 1) of \(clipBatch?.total ?? 1)" : "the lyric video"
            videoJob = "Making \(which)" + (used == 1 ? "…" : " (\(used) pictures" + (used < pictures.count ? " of \(pictures.count))…" : ")…"))
        }
        videoProgress = kind == .lyricVideo ? 0 : nil
        currentID = song.id
        startClock()
        var written: URL?
        do {
            current = try ScriptRun(script: script, arguments: args, onLine: { [weak self] line in
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("Written:") {
                    let url = URL(fileURLWithPath: text.dropFirst(8).trimmingCharacters(in: .whitespaces))
                    DispatchQueue.main.async { written = url }
                } else if text.hasPrefix("progress "), let value = Double(text.dropFirst(9)) {
                    DispatchQueue.main.async { self?.videoProgress = value }
                }
            }, onExit: { [weak self] status, errors in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let stopped = self.current?.wasStopped ?? false
                    self.current = nil
                    self.currentID = nil
                    self.videoJob = nil
                    self.videoProgress = nil
                    self.stopClock()
                    guard let j = self.songs.firstIndex(where: { $0.id == id }) else { self.clipBatch = nil; return }
                    // several lyric videos: the next one starts at once, with a new random draw
                    if kind == .lyricVideo, status == 0, !stopped, let batch = self.clipBatch, batch.done + 1 < batch.total {
                        self.clipBatch = (batch.done + 1, batch.total)
                        self.songs[j].videoURL = written
                        self.songs[j].note = "Video \(batch.done + 1) of \(batch.total) ready: \(written?.lastPathComponent ?? "")."
                        self.makeVideo(.lyricVideo, for: id, pictures: pictures)
                        return
                    }
                    let batchTotal = kind == .lyricVideo ? (self.clipBatch?.total ?? 1) : 1
                    if kind == .lyricVideo { self.clipBatch = nil }
                    if status == 0, let written {
                        self.songs[j].videoURL = written
                        self.songs[j].note = kind == .overlay
                            ? "iMovie: put the song and your pictures in the timeline, drag this video above them at 0:00, then Video Overlay Settings › Green/Blue Screen."
                            : batchTotal > 1 ? "\(batchTotal) videos ready, each with its own random draw (the .txt beside each one lists its pictures)."
                            : "Video ready: \(written.lastPathComponent)" + (kind == .lyricVideo ? " (its settings and picture times are in the .txt beside it)." : ".")
                        NSWorkspace.shared.activateFileViewerSelecting([written])
                    } else if !stopped {
                        let last = errors.split(separator: "\n").suffix(2).joined(separator: " ")
                        self.songs[j].note = "The video could not be made. " + last
                    }
                    self.runNext()
                }
            })
        } catch {
            videoJob = nil
            videoProgress = nil
            currentID = nil
            stopClock()
            songs[i].note = error.localizedDescription
        }
    }

    // MARK: Tempo

    private var tempoRuns: [Song.ID: ScriptRun] = [:]

    /// The tempo, measured once per song (half a second) and shown above the lyrics.
    func detectTempo(_ id: Song.ID) {
        guard tempoRuns[id] == nil, let clip = Paths.clipScript,
              let song = songs.first(where: { $0.id == id }), song.bpm == nil else { return }
        var found: Double?
        tempoRuns[id] = try? ScriptRun(script: clip, arguments: ["bpm", song.url.path], onLine: { line in
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let bpm = json["bpm"] as? Double { found = bpm }
        }, onExit: { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.tempoRuns[id] = nil
                if let j = self.songs.firstIndex(where: { $0.id == id }) { self.songs[j].bpm = found }
            }
        })
    }

    // MARK: Listening

    private func openSelectedInPlayer() {
        guard let song = selectedSong else { Player.shared.load(nil); return }
        if Player.shared.url != song.url { Player.shared.load(song.url) }
    }
}

// MARK: - Player

/// Plays the selected song, so that each line can be checked by ear.
final class Player: ObservableObject {
    static let shared = Player()

    @Published private(set) var url: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var now: Double = 0
    @Published private(set) var length: Double = 0

    private var audio: AVAudioPlayer?
    private var timer: Timer?

    func load(_ newURL: URL?) {
        stop()
        url = newURL
        now = 0
        audio = newURL.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        audio?.prepareToPlay()
        length = audio?.duration ?? 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play(from time: Double? = nil) {
        guard let audio else { return }
        if let time { audio.currentTime = max(0, min(time, audio.duration - 0.05)) }
        audio.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func pause() {
        audio?.pause()
        isPlaying = false
        timer?.invalidate()
        tick()
    }

    func stop() { audio?.stop(); isPlaying = false; timer?.invalidate() }

    func seek(by delta: Double) {
        guard let audio else { return }
        audio.currentTime = max(0, min(audio.currentTime + delta, audio.duration - 0.05))
        tick()
    }

    func seek(to time: Double) {
        guard let audio else { return }
        audio.currentTime = max(0, min(time, audio.duration - 0.05))
        tick()
    }

    private func tick() {
        guard let audio else { return }
        now = audio.currentTime
        if !audio.isPlaying && isPlaying {           // reached the end
            isPlaying = false
            timer?.invalidate()
        }
    }
}

// MARK: - Main view: settings | songs and lyrics | post-processing

extension View {
    /// A side column, on the window's own background.
    func sidePanel() -> some View { self.background(Color(nsColor: .windowBackgroundColor)) }
}

struct ContentView: View {
    @EnvironmentObject var model: LyricsModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 310).sidePanel()
            Divider()
            Group {
                if let song = model.selectedSong { SongEditor(songID: song.id) } else { EmptyState() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PostPanel().frame(width: 270).sidePanel()
        }
        .frame(minWidth: 1100, minHeight: 640)
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted, perform: handleDrop)
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var dropped: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let url { lock.lock(); dropped.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { model.add(dropped) }
        return true
    }
}

// MARK: - Left: settings, then the list of songs

struct Sidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AppInfo.name).font(.title2.bold())
                    Text("v\(AppInfo.version)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(AppInfo.engineName).font(.caption).foregroundStyle(.tertiary)
                }
                Text("Drop songs on the window to get their sung words with timing, as .lrc, .srt and .txt.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                SettingsSection()
            }
            .padding(16)
            Divider()
            SongList()
        }
    }
}

struct SettingsSection: View {
    @EnvironmentObject var model: LyricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Language").font(.headline)
                    Spacer()
                    Picker("", selection: $model.language) {
                        ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden().frame(width: 140)
                }
                Text("“Detect” works for most songs. Choose the language if a song comes back in the wrong one.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $model.isolateVoice) { Text("Isolate the voice first").font(.headline) }
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(!Paths.canIsolateVoice)
                Text(Paths.canIsolateVoice
                     ? "Slower (about a minute per song). Helps when the voice is buried under loud instruments; often worse on airy, reverberant voices."
                     : "Not available right now: songs are transcribed from the whole mix.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Lyrics folder").font(.headline)
                    Spacer()
                    Picker("", selection: Binding(get: { model.place }, set: { newValue in
                        if newValue == .custom { model.chooseCustomFolder() } else { model.place = newValue }
                    })) {
                        ForEach(OutputPlace.allCases) { Text($0 == .custom && model.customFolder != nil
                                                             ? model.customFolder!.lastPathComponent : $0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                    Button { model.revealOutputRoot() } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Open this folder in the Finder")
                }
                Text(folderCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Text file").font(.headline)
                    Spacer()
                    Picker("", selection: $model.textStyle) {
                        ForEach(TextStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                Text(model.textStyle == .withTimes ? "The .txt reads “00:20.74  words”, one line each."
                                                   : "The .txt holds the words alone. The .lrc and .srt always carry the times.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var folderCaption: String {
        switch model.place {
        case .movies: return "Each song gets its own folder in Movies › Lyrics. The song itself is never touched."
        case .beside: return "The files go next to the song, unless its folder is protected."
        case .custom: return "Each song gets its own folder in “\(model.customFolder?.path ?? "")”."
        }
    }
}

struct SongList: View {
    @EnvironmentObject var model: LyricsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Songs").font(.headline)
                if !model.songs.isEmpty { Text("\(model.songs.count)").foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                if model.songs.contains(where: { $0.state == .done || $0.state == .stopped || isFailed($0) }) {
                    Button("Clear Finished") { model.clearFinished() }.buttonStyle(.borderless).font(.callout)
                        .help("Removes the finished songs from this list. Their files stay where they are.")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            if model.songs.isEmpty {
                Text("No songs yet.").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.songs) { song in
                        SongRow(song: song).tag(song.id)
                            .contextMenu {
                                Button("Transcribe Again") { model.transcribeAgain(song.id) }.disabled(song.isBusy || model.isWorking)
                                Button("Show in Finder") { model.reveal(song) }
                                Divider()
                                Button("Remove from List") { model.remove(song.id) }.disabled(song.isBusy)
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            if model.isWorking {
                Divider()
                ProgressFooter()
            }
        }
    }

    private func isFailed(_ song: Song) -> Bool { if case .failed = song.state { return true } else { return false } }
}

struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if song.dirty { Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Edited, not saved yet") }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch song.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        switch song.state {
        case .waiting: return "Waiting"
        case .working(let what): return what
        case .done: return "\(song.lines.count) lines" + (song.language.map { " · \($0)" } ?? "") + " · " + clock(song.duration)
        case .failed: return "Failed — select it to see why"
        case .stopped: return "Stopped"
        }
    }
}

struct ProgressFooter: View {
    @EnvironmentObject var model: LyricsModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.videoJob ?? (model.waitingCount > 0 ? "Transcribing · \(model.waitingCount) more waiting" : "Transcribing"))
                    .font(.callout)
                Text("\(model.elapsed) s · usually about 5 s a song").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop") { model.stopEverything() }
                .help("Stops the job in progress and the songs still waiting. Nothing already written is lost.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Middle: the lyrics of one song

/// "Movies › Lyrics › Song" for a folder under the home folder, the full path otherwise.
func friendlyPath(_ url: URL) -> String {
    let home = Paths.home.path
    let path = url.path.hasPrefix(home + "/") ? String(url.path.dropFirst(home.count + 1)) : url.path
    return path.split(separator: "/").joined(separator: " › ")
}

struct SongEditor: View {
    @EnvironmentObject var model: LyricsModel
    @EnvironmentObject var player: Player
    let songID: Song.ID

    var body: some View {
        if let song = model.songs.first(where: { $0.id == songID }) {
            VStack(spacing: 0) {
                header(song)
                Divider()
                content(song)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func header(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(song.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                .help(song.url.path)
            // where the lyrics are: one click opens the folder
            HStack(spacing: 6) {
                Text("Lyrics in").foregroundStyle(.secondary)
                Button { model.reveal(song) } label: {
                    Text(friendlyPath(song.folder)).underline().lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.link)
                .help("Show the lyrics files in the Finder")
            }
            .font(.callout)
            if song.state == .done { transport }
            if !song.note.isEmpty {
                Text(song.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Play / pause (space bar)")
            Text("\(clock(player.now, tenths: true)) / \(clock(player.length))").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { player.now }, set: { player.seek(to: $0) }), in: 0...max(player.length, 0.1))
            if let bpm = model.selectedSong?.bpm {
                Label(String(format: bpm.rounded() == bpm ? "%.0f BPM" : "%.1f BPM", bpm), systemImage: "metronome")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .help("The tempo, measured from the beats over the whole song")
            }
        }
    }

    @ViewBuilder private func content(_ song: Song) -> some View {
        switch song.state {
        case .done:
            if song.lines.isEmpty {
                VStack(spacing: 12) {
                    Text("No sung words were heard.").font(.title3).foregroundStyle(.secondary)
                    Text("An instrumental? The Lyric Video on the right still makes a clip with the pictures and the sound.")
                        .foregroundStyle(.secondary)
                    Button("Add a Line at the Current Time") { model.addFirstLine(to: song.id) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LinesView(song: song)
            }
        case .waiting:
            centered(icon: "clock", title: "Waiting", text: "This song is next in line.")
        case .working(let what):
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(what).font(.title3)
                Text("\(model.elapsed) s").monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.red)
                Text("The lyrics could not be made").font(.title3)
                Text(why).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: 560)
                Button("Try Again") { model.transcribeAgain(song.id) }.disabled(model.isWorking)
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .stopped:
            VStack(spacing: 12) {
                centered(icon: "stop.circle", title: "Stopped", text: "Nothing was written for this song.")
                Button("Transcribe") { model.transcribeAgain(song.id) }.disabled(model.isWorking)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func centered(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The timed lines: click ▶ to hear a line, nudge its time, retype its words.
struct LinesView: View {
    @EnvironmentObject var model: LyricsModel
    @EnvironmentObject var player: Player
    let song: Song

    private var currentLine: LyricLine.ID? {
        guard player.url == song.url, player.now > 0 || player.isPlaying else { return nil }
        return song.lines.last(where: { $0.time <= player.now + 0.02 })?.id
    }

    var body: some View {
        let playing = currentLine
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("The words are what Whisper hears: when they are unclear or invented, they are a best guess. The times are reliable (within about 0.3 s). Click ▶ to hear a line, ↧ to set its start to the playing time.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 8)
                    ForEach(song.lines) { line in
                        if let binding = model.binding(for: line.id, in: song.id) {
                            LineRow(line: binding, isCurrent: playing == line.id, songID: song.id)
                                .id(line.id)
                        }
                    }
                    Color.clear.frame(height: 40)
                }
            }
            .onChange(of: playing) { _, id in
                guard player.isPlaying, let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { scroller.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct LineRow: View {
    @EnvironmentObject var model: LyricsModel
    @EnvironmentObject var player: Player
    @Binding var line: LyricLine
    let isCurrent: Bool
    let songID: Song.ID

    var body: some View {
        HStack(spacing: 8) {
            Button { player.play(from: line.time) } label: { Image(systemName: "play.fill").font(.caption) }
                .buttonStyle(.borderless).help("Play from this line")
            TimeField(time: $line.time)
            HStack(spacing: 0) {
                Button { line.time = max(0, ((line.time - 0.1) * 100).rounded() / 100) } label: { Image(systemName: "minus") }
                    .help("0.1 s earlier")
                Button { line.time = ((line.time + 0.1) * 100).rounded() / 100 } label: { Image(systemName: "plus") }
                    .help("0.1 s later")
            }
            .buttonStyle(.borderless).font(.caption)
            Button { line.time = (player.now * 100).rounded() / 100 } label: { Image(systemName: "arrow.down.to.line") }
                .buttonStyle(.borderless).font(.caption)
                .help("Start this line at the playing time (\(LyricsFiles.lrcStamp(player.now)))")
            TextField("", text: $line.text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(isCurrent ? Color.accentColor.opacity(0.14) : Color.clear)
        .contextMenu {
            Button("Insert a Line Below") { model.insertLine(after: line.id, in: songID) }
            Button("Delete This Line") { model.deleteLine(line.id, in: songID) }
        }
    }
}

/// "01:20.50": typed freely, read when Return is pressed or the field is left.
struct TimeField: View {
    @Binding var time: Double
    @StateObject private var box = DraftBox()      // (@State needs a compiler plug-in the command line tools lack)
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $box.draft)
            .font(.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 78)
            .focused($focused)
            .onAppear { box.draft = LyricsFiles.lrcStamp(time) }
            .onChange(of: time) { _, t in if !focused { box.draft = LyricsFiles.lrcStamp(t) } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit { commit(); NSApp.keyWindow?.makeFirstResponder(nil) }
            .help("Start time, minutes:seconds")
    }

    private func commit() {
        if let t = LyricsFiles.parseStamp(box.draft) { time = (t * 100).rounded() / 100 }
        box.draft = LyricsFiles.lrcStamp(time)
    }
}

final class DraftBox: ObservableObject { @Published var draft = "" }

struct EmptyState: View {
    @EnvironmentObject var model: LyricsModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Drop songs here").font(.title2)
            Text("WAV, MP3, FLAC, M4A or AIFF · one song, several, or a whole folder").foregroundStyle(.secondary)
            Button("Choose Songs…") { model.chooseFiles() }.controlSize(.large)
            if !model.message.isEmpty { Text(model.message).foregroundStyle(.orange).padding(.top, 6) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .foregroundStyle(.tertiary)
                .padding(28)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Right: post-processing

/// Everything done with the lyrics once they exist: save, copy, open, videos.
struct PostPanel: View {
    @EnvironmentObject var model: LyricsModel

    var body: some View {
        let song = model.selectedSong
        let ready = song?.state == .done
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Post-processing").font(.title3.bold())

                // The button used all the time: big, coloured, first.
                Button { if let song { model.reveal(song) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show in Finder").font(.headline)
                            Text("The lyrics and videos of this song").font(.caption).opacity(0.85)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 4)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.13, green: 0.62, blue: 0.42))
                .controlSize(.extraLarge)
                .disabled(song == nil)
                .help("Opens the song’s lyrics folder in the Finder, with the latest file selected")

                section("Lyrics") {
                    Button { model.saveSelected() } label: {
                        PanelLabel(song?.dirty == true ? "Save Changes" : "Saved", "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(song?.dirty ?? false))
                    .help("Writes the .lrc, .srt and .txt with your changes (⌘S)")
                    Button { if let song { model.copyLyrics(song, withTimes: false) } } label: {
                        PanelLabel("Copy Lyrics", "doc.on.doc")
                    }
                    .disabled(!ready)
                    Button { if let song { model.copyLyrics(song, withTimes: true) } } label: {
                        PanelLabel("Copy with Times", "clock")
                    }
                    .disabled(!ready)
                    Button { if let song { model.openInTextEdit(song) } } label: {
                        PanelLabel("Open in TextEdit", "doc.text")
                    }
                    .disabled(!ready)
                }

                section("Lyric Video") {
                    LyricVideoSettings()
                    Divider()
                    // 1. choose the pictures (nothing starts yet)
                    Button { model.chooseClipPictures() } label: {
                        PanelLabel(model.clipPictures.isEmpty ? "Choose Pictures…" : "Choose Other Pictures…", "photo.on.rectangle.angled")
                    }
                    .help("One picture, several, or a folder. They follow the order of their file names, and change where the lyrics change.")
                    HStack {
                        Text(model.clipPictures.isEmpty ? "No pictures chosen yet."
                             : model.clipPictures.count == 1 ? "1 picture chosen: \(model.clipPictures[0].lastPathComponent)"
                             : "\(model.clipPictures.count) pictures chosen")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        if !model.clipPictures.isEmpty {
                            Button("Clear") { model.clipPictures = [] }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                    // 2. how many videos (only meaningful when each one is drawn at random)
                    if model.clipIsRandom {
                        HStack(spacing: 6) {
                            Text("Number of videos:")
                            TextField("", value: $model.clipCount, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing)
                                .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
                            Stepper("", value: $model.clipCount, in: 1...50).labelsHidden()
                        }
                        Text("Each video gets its own random draw.").font(.caption).foregroundStyle(.secondary)
                    }
                    // 3. run
                    let count = model.clipIsRandom ? max(1, min(model.clipCount, 50)) : 1
                    Button { if let song { model.makeLyricVideos(for: song.id) } } label: {
                        PanelLabel(count == 1 ? "Make the Video" : "Make \(count) Videos", "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.clipPictures.isEmpty || model.isWorking || !Paths.hasVideoTools)
                    if model.clipOriginalSound {
                        Toggle("Also in MP4", isOn: $model.clipAlsoMP4).toggleStyle(.checkbox)
                        Text("A WAV song makes a .mov, which Discord and some sites refuse. This adds an .mp4 beside it (same picture, AAC sound).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !Paths.hasVideoTools {
                        Text("Lyric videos need Python with numpy and Pillow. In Terminal: python3 -m pip install --user numpy pillow")
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let progress = model.videoProgress {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: progress)
                            HStack {
                                Text("\(Int(progress * 100)) % · \(model.elapsed) s").font(.caption).foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Spacer()
                                Button("Stop") { model.stopEverything() }.controlSize(.small)
                            }
                        }
                    }
                }
                .disabled(!ready || (model.isWorking && model.videoProgress == nil))

                section("Other Videos") {
                    Button { if let song { model.makeVideo(.quicktime, for: song.id) } } label: {
                        PanelLabel("QuickTime Video", "play.rectangle")
                    }
                    .help("The song with the words as subtitles, to check the timing (QuickTime, VLC)")
                    Button { if let song { model.makeVideo(.overlay, for: song.id) } } label: {
                        PanelLabel("iMovie Green Screen", "rectangle.on.rectangle")
                    }
                    .help("White words on pure green, no sound: lay it over your pictures in iMovie")
                    if let job = model.videoJob, model.videoProgress == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(job).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!ready || model.isWorking)

                section("Transcription") {
                    Button { if let song { model.transcribeAgain(song.id) } } label: {
                        PanelLabel("Transcribe Again", "arrow.clockwise")
                    }
                    .disabled(song == nil || song?.isBusy == true || model.isWorking)
                    Text("Your edits are never overwritten: a new transcription of an edited song goes to separate .whisper files.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .controlSize(.large)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
            content()
        }
    }
}

/// The settings of the lyric video: frame, cropping, Ken Burns, cuts on the beat.
struct LyricVideoSettings: View {
    @EnvironmentObject var model: LyricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormatPicker(selection: $model.clipFormat)
            Text(model.clipFormat.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Crop pictures to fill the frame", isOn: $model.clipCrop).toggleStyle(.checkbox)
            Text(model.clipCrop ? "Pictures of another shape are cropped." : "Each picture is shown whole, with black bars where it does not fill the frame.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Ken Burns effect", isOn: $model.kenBurns).toggleStyle(.checkbox)
            if model.kenBurns {
                VStack(spacing: 2) {
                    Slider(value: $model.kenBurnsAmount, in: 0...1).controlSize(.small)
                    HStack {
                        Text("Very light"); Spacer()
                        Text("zoom \(Int((4 + 21 * model.kenBurnsAmount).rounded())) %").monospacedDigit(); Spacer()
                        Text("Pronounced")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ShareRow(label: "On", value: $model.kenBurnsShare, unit: "% of the pictures")
                Text("The chosen pictures slowly zoom in or out and drift in a straight line; the others stay still. Moving pictures take longer to make.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Crossfades", isOn: $model.crossfades).toggleStyle(.checkbox)
            if model.crossfades {
                ShareRow(label: "On", value: $model.crossfadeShare, unit: "% of the cuts")
                Text("These pictures dissolve into the next one (1 second, shorter between quick pictures); the other cuts stay sharp.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Show the words", isOn: $model.clipWords).toggleStyle(.checkbox)
            Text(model.selectedSong?.lines.isEmpty == true ? "No words in this song: the video has the pictures and the sound only."
                 : model.clipWords ? "The lyrics are drawn over the pictures."
                 : "Pictures and sound only, to add your own titles in iMovie. The cuts still follow the lyrics.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Keep the original sound", isOn: $model.clipOriginalSound).toggleStyle(.checkbox)
            Text(model.clipOriginalSound ? "The song’s own sound, untouched. From a WAV the video is a .mov (QuickTime and iMovie read it)."
                 : "Compressed sound (AAC 320 kb/s) in an .mp4, smaller and readable everywhere.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Toggle("Pick at random:", isOn: $model.clipPick).toggleStyle(.checkbox)
                TextField("", value: $model.clipPickCount, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 50).multilineTextAlignment(.trailing)
                    .disabled(!model.clipPick)
                    .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
                Text("pictures").foregroundStyle(model.clipPick ? .primary : .secondary)
            }
            Toggle("Shuffle the order", isOn: $model.clipShuffle).toggleStyle(.checkbox)
            Text(model.clipPick
                 ? "Select many pictures: \(model.clipPickCount) of them are drawn at random, a new draw every time. " + (model.clipShuffle ? "Their order is mixed too." : "They keep the order of their names.")
                 : model.clipShuffle ? "The pictures come in a random order, a new one every time." : "All the chosen pictures are used, in the order of their names.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Cut on the beat", isOn: $model.cutOnBeat).toggleStyle(.checkbox)
                .disabled(model.selectedSong?.bpm == nil)
            Text(model.selectedSong?.bpm == nil ? "Waiting for the tempo of this song."
                 : "With several pictures, each change of picture lands on a beat, as close as possible to a change of lyrics.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.regular)
    }
}

/// The frame shapes as small proportional outlines, landscape on the first row, portrait on the second.
struct FormatPicker: View {
    @Binding var selection: ClipFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(ClipFormat.horizontal)
            row(ClipFormat.vertical)
        }
    }

    private func row(_ formats: [ClipFormat]) -> some View {
        HStack(spacing: 4) {
            ForEach(formats) { format in
                Button { selection = format } label: { FormatIcon(format: format, selected: selection == format) }
                    .buttonStyle(.plain)
                    .help(format.help)
            }
        }
    }
}

struct FormatIcon: View {
    let format: ClipFormat
    let selected: Bool

    var body: some View {
        let (w, h) = format.ratio
        let box: CGFloat = 26
        let scale = box / CGFloat(max(w, h))
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary, lineWidth: selected ? 2 : 1.2)
            }
            .frame(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
            .frame(width: box, height: box)
            Text(format.rawValue).font(.caption2.monospacedDigit())
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .fontWeight(selected ? .semibold : .regular)
        }
        .frame(width: 44, height: 46)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
    }
}

/// "On [ 20 ] % of the pictures", with a slider under it.
struct ShareRow: View {
    let label: String
    @Binding var value: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                Text("\(Int(value.rounded()))").monospacedDigit().fontWeight(.semibold)
                Text(unit)
            }
            .font(.callout)
            Slider(value: Binding(get: { value }, set: { value = ($0 / 5).rounded() * 5 }), in: 0...100).controlSize(.small)
        }
    }
}

/// A full-width button label with its icon on the left.
struct PanelLabel: View {
    let title: String
    let icon: String
    init(_ title: String, _ icon: String) { self.title = title; self.icon = icon }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18)
            Text(title)                                   // wraps onto a second line rather than being cut
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 136.4 -> "2:16"  (tenths: "2:16.4")
func clock(_ seconds: Double, tenths: Bool = false) -> String {
    let s = max(0, seconds)
    let m = Int(s / 60)
    return tenths ? String(format: "%d:%04.1f", m, s - Double(m) * 60) : String(format: "%d:%02d", m, Int(s) % 60)
}
