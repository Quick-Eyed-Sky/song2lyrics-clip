// The engine: runs lyrics.py (the song-lyrics script), never a copy of its pipeline.
//
// Everything that decides HOW the words are heard (whisper.cpp large-v3-turbo, -mc 0, DTW word times, no VAD,
// the optional BS-Roformer vocal stem) lives in lyrics.py. This file only starts it, reads what it prints,
// and stops it.

import Foundation

enum AppInfo {
    /// The name comes from the app's Info.plist, so that the same code builds under another name.
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Song2Lyrics Clip"
    static let version = "0.14.1"
    static let engineName = "Whisper large-v3-turbo"
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The skill's own script comes first, so that an improvement to the skill reaches the app at once.
    /// The copy inside the app is only a fallback, if the skill folder is ever moved.
    static var script: URL? {
        let skill = home.appendingPathComponent(".claude/skills/song-lyrics/scripts/lyrics.py")
        if FileManager.default.fileExists(atPath: skill.path) { return skill }
        if let bundled = Bundle.main.url(forResource: "lyrics", withExtension: "py", subdirectory: "scripts") { return bundled }
        return nil
    }

    /// The app's own lyric-video maker and tempo detector (it imports the skill's lyrics.py for the words).
    static var clipScript: URL? {
        Bundle.main.url(forResource: "clip", withExtension: "py", subdirectory: "scripts")
    }

    /// The Python that runs the scripts: the first one that has numpy and Pillow (needed for the videos and the
    /// tempo), else the first one found (the transcription needs neither). A Python of your choice can be set with
    ///   defaults write <bundle id> python /path/to/python
    /// Nothing is ever installed into any of them.
    static let python: URL = {
        var candidates: [String] = []
        if let chosen = ProcessInfo.processInfo.environment["SONG_LYRICS_PYTHON"] { candidates.append(chosen) }
        if let chosen = UserDefaults.standard.string(forKey: "python") { candidates.append((chosen as NSString).expandingTildeInPath) }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let present = candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
        let complete = present.first { path in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-c", "import numpy, PIL"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        foundVideoTools = complete != nil
        return URL(fileURLWithPath: complete ?? present.first ?? "/usr/bin/python3")
    }()

    private static var foundVideoTools = false

    /// False when no Python with numpy and Pillow was found: lyric videos and the tempo are then unavailable.
    /// Asking for it makes the search first, which starts programs and waits for them: never call it from a view's
    /// body (the window would be redrawn in the middle of the search). LyricsModel asks once, in the background.
    static var hasVideoTools: Bool { _ = python; return foundVideoTools }

    /// Folders the app never writes into, even with "Next to each song" (reference material). Set with
    ///   defaults write <bundle id> protectedFolders -array "/Music/Masters/"
    static var protectedFolders: [String] { UserDefaults.standard.stringArray(forKey: "protectedFolders") ?? [] }

    static let defaultOutput = home.appendingPathComponent("Movies/Lyrics")
    static let whisperModel = home.appendingPathComponent(".cache/whisper.cpp/ggml-large-v3-turbo.bin")
    static var separator: String {
        let candidates: [String?] = [ProcessInfo.processInfo.environment["SONG_LYRICS_SEPARATOR"], "/opt/homebrew/bin/audio-separator",
                          home.appendingPathComponent(".local/bin/audio-separator").path]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
    static let separatorModel = home.appendingPathComponent(".cache/audio-separator/model_bs_roformer_ep_317_sdr_12.9755.ckpt")

    static var canIsolateVoice: Bool {
        FileManager.default.isExecutableFile(atPath: separator) && FileManager.default.fileExists(atPath: separatorModel.path)
    }
}

/// What the Mac is doing that uses the same GPU memory: a vocal separation started next to a big render once
/// crashed a 64 GB Mac. Only looks: it never stops anything.
enum GPUNeighbours {
    static func busy() -> [String] {
        var found: [String] = []
        if listed("yue_runner") { found.append("a YuE render") }
        if listed("Draw Things.app/Contents/MacOS") { found.append("Draw Things") }
        return found
    }

    private static func listed(_ pattern: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// One run of lyrics.py. The lines it prints arrive one by one in `onLine`; `onExit` gets the exit status and
/// everything it wrote on stderr (its error message, when it fails).
final class ScriptRun {
    private let process = Process()
    private var stdoutBuffer = Data()
    private var stderrText = ""
    private let lock = NSLock()
    private(set) var wasStopped = false

    init(script chosen: URL? = nil, arguments: [String], onLine: @escaping (String) -> Void,
         onExit: @escaping (Int32, String) -> Void) throws {
        guard let script = chosen ?? Paths.script else {
            throw NSError(domain: AppInfo.name, code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The song-lyrics script was not found (~/.claude/skills/song-lyrics/scripts/lyrics.py)."])
        }
        process.executableURL = Paths.python
        process.arguments = ["-u", script.path] + arguments          // -u: lines arrive as they are printed
        var env = ProcessInfo.processInfo.environment
        // An app started from the Finder does not see Homebrew: give it the same PATH as the Terminal.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self.lock.lock()
            self.stdoutBuffer.append(chunk)
            var lines: [String] = []
            while let nl = self.stdoutBuffer.firstIndex(of: 0x0A) {
                let line = String(decoding: self.stdoutBuffer[..<nl], as: UTF8.self)
                self.stdoutBuffer.removeSubrange(...nl)
                lines.append(line)
            }
            self.lock.unlock()
            lines.forEach(onLine)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self?.lock.lock(); self?.stderrText += String(decoding: chunk, as: UTF8.self); self?.lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            // what is left in the pipes after the last newline
            let restOut = out.fileHandleForReading.readDataToEndOfFile()
            let restErr = err.fileHandleForReading.readDataToEndOfFile()
            self.lock.lock()
            self.stdoutBuffer.append(restOut)
            let tail = String(decoding: self.stdoutBuffer, as: UTF8.self)
            self.stderrText += String(decoding: restErr, as: UTF8.self)
            let errors = self.stderrText
            self.lock.unlock()
            tail.split(separator: "\n").map(String.init).forEach(onLine)
            onExit(p.terminationStatus, errors)
        }
        try process.run()
    }

    /// Stops this run and only this one: its own process and the programs it started (whisper-cli, ffmpeg,
    /// audio-separator), found by their parent's process number -- never by a name, which could hit
    /// another program of the same name running on the Mac.
    func stop() {
        wasStopped = true
        let pid = process.processIdentifier
        for child in ScriptRun.descendants(of: pid).reversed() { kill(child, SIGTERM) }
        if process.isRunning { process.terminate() }
    }

    private static func descendants(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let children = text.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return children.flatMap { [$0] + descendants(of: $0) }
    }
}
