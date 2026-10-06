// Reading and writing the three lyrics files (.lrc, .srt, .txt).
//
// The timing rules are the same as lyrics.py's (stamp_lrc, stamp_srt, cues_from_lines), so a file saved by the
// app after an edit looks exactly like one the script wrote.

import Foundation

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    var time: Double          // seconds from the start of the song
    var text: String
}

/// How the .txt is written: the bare words, or each line with its start time.
enum TextStyle: String, CaseIterable, Identifiable {
    case withTimes = "With times"
    case wordsOnly = "Words only"
    var id: String { rawValue }
}

enum LyricsFiles {
    // MARK: Time stamps

    /// 80.5 -> "01:20.50" (LRC)
    static func lrcStamp(_ t: Double) -> String {
        let t = max(0, t)
        let minutes = Int(t / 60)
        return String(format: "%02d:%05.2f", minutes, t - Double(minutes) * 60)
    }

    /// 80.5 -> "00:01:20,500" (SRT)
    static func srtStamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// "1:20.5", "01:20.50", "80.5" -> seconds. Nil if it cannot be read.
    static func parseStamp(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":")
        if parts.count == 1 { return Double(parts[0]).flatMap { $0 >= 0 ? $0 : nil } }
        if parts.count == 2, let m = Int(parts[0]), let sec = Double(parts[1]), m >= 0, sec >= 0, sec < 60 {
            return Double(m) * 60 + sec
        }
        return nil
    }

    // MARK: LRC

    struct LRC {
        var tags: [String] = []      // "[ti:...]", "[re:...]" header rows, kept as they were
        var lines: [LyricLine] = []
    }

    private static let stampPattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)

    static func readLRC(_ url: URL) throws -> LRC {
        var text = try String(contentsOf: url, encoding: .utf8)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var result = LRC()
        var offset = 0.0
        for row in text.components(separatedBy: .newlines) {
            let ns = row as NSString
            let matches = stampPattern.matches(in: row, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                let trimmed = row.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.contains(":") {
                    result.tags.append(trimmed)
                    if trimmed.lowercased().hasPrefix("[offset:"),
                       let ms = Double(trimmed.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)) {
                        offset = ms / 1000          // LRC: a positive offset shows the words earlier
                    }
                }
                continue
            }
            let words = stampPattern.stringByReplacingMatches(in: row, range: NSRange(location: 0, length: ns.length),
                                                              withTemplate: "").trimmingCharacters(in: .whitespaces)
            if words.isEmpty { continue }
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                result.lines.append(LyricLine(time: minutes * 60 + seconds - offset, text: words))
            }
        }
        // an [offset:] has been applied to the times above, so it must not be applied twice on saving
        result.tags.removeAll { $0.lowercased().hasPrefix("[offset:") }
        result.lines.sort { $0.time < $1.time }
        return result
    }

    // MARK: Cues (when each line appears and disappears, for .srt)

    /// A line stays until the next one, but not longer than its reading time allows (same rule as lyrics.py).
    static func cues(_ lines: [LyricLine], total: Double) -> [(start: Double, end: Double, text: String)] {
        let sorted = lines.sorted { $0.time < $1.time }
        return sorted.enumerated().map { i, line in
            let next = i + 1 < sorted.count ? sorted[i + 1].time : total
            let show = min(7.0, max(3.0, 2.0 + 0.09 * Double(line.text.count)))
            let end = max(line.time + 0.5, min(next - 0.05, line.time + show, total))
            return (line.time, end, line.text)
        }
    }

    // MARK: Writing

    /// Writes the three files beside each other. Returns them in the order .lrc, .srt, .txt.
    @discardableResult
    static func writeAll(lrc: URL, tags: [String], lines: [LyricLine], total: Double, textStyle: TextStyle) throws -> [URL] {
        let sorted = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.time < $1.time }
        let base = lrc.deletingPathExtension()
        let name = base.lastPathComponent              // "song", or "song.whisper": the .srt and .txt follow the .lrc
        let folder = lrc.deletingLastPathComponent()

        let header = tags.isEmpty ? ["[ti:\(name.replacingOccurrences(of: ".whisper", with: ""))]"] : tags
        let lrcText = header.map { $0 + "\n" }.joined()
            + sorted.map { "[\(lrcStamp($0.time))]\($0.text)\n" }.joined()
        try lrcText.write(to: lrc, atomically: true, encoding: .utf8)

        let srt = folder.appendingPathComponent(name + ".srt")
        let srtText = cues(sorted, total: total).enumerated().map { i, c in
            "\(i + 1)\n\(srtStamp(c.start)) --> \(srtStamp(c.end))\n\(c.text)\n\n"
        }.joined()
        try srtText.write(to: srt, atomically: true, encoding: .utf8)

        let txt = try writeText(folder: folder, name: name, lines: sorted, style: textStyle)
        return [lrc, srt, txt]
    }

    /// The .txt alone (after a transcription, so that it follows the app's "With times / Words only" choice
    /// without touching the .lrc -- a newer .lrc would look like a hand edit to lyrics.py).
    @discardableResult
    static func writeText(folder: URL, name: String, lines: [LyricLine], style: TextStyle) throws -> URL {
        let txt = folder.appendingPathComponent(name + ".txt")
        let body = lines.sorted { $0.time < $1.time }.map { line in
            style == .withTimes ? "\(lrcStamp(line.time))  \(line.text)\n" : "\(line.text)\n"
        }.joined()
        try body.write(to: txt, atomically: true, encoding: .utf8)
        return txt
    }
}
