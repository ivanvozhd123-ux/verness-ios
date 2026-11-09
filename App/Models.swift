import Foundation

struct Track: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var duration: Double
    var cover: String?
    var file: String?
    var videoId: String?
    var local: Bool { file != nil }
}

struct Playlist: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var tracks: [String] = []
}

enum RepeatMode: String, Codable, CaseIterable { case off, all, one }

struct Preferences: Codable {
    var theme = "dark"
    var language = "ru"
    var accent = "#66db1b"
    var speed: Float = 1
    var volume: Float = 0.7
    var eqEnabled = false
    var bands: [Float] = Array(repeating: 0, count: 10)
    var preamp: Float = 0
    var protect = true
    var repeatMode: RepeatMode = .off
    var shuffle = false
    var server = ""
    var liveActivity = true
    var artists: [String] = []
}

struct LibraryData: Codable {
    var schema = 1
    var tracks: [Track] = []
    var favorites: Set<String> = []
    var playlists: [Playlist] = []
    var preferences = Preferences()
}

struct LyricLine: Identifiable, Equatable {
    var id: Int
    var time: Double?
    var text: String
}

enum LRC {
    static func parse(_ text: String) -> [LyricLine] {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let ns = text as NSString
        var offset: Double = 0
        for match in offsetPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            offset = (Double(ns.substring(with: match.range(at: 1))) ?? 0) / 1000
        }
        var rows: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: line.length))
            guard let last = matches.last else { continue }
            let value = line.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minute = Double(line.substring(with: match.range(at: 1))) ?? 0
                let second = Double(line.substring(with: match.range(at: 2))) ?? 0
                rows.append((max(0, minute * 60 + second + offset), value))
            }
        }
        rows.sort { $0.0 < $1.0 }
        return rows.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

enum QueueRules {
    static func next(index: Int, count: Int, direction: Int, automatic: Bool, repeatMode: RepeatMode) -> Int? {
        guard count > 0 else { return nil }
        if automatic && repeatMode == .one { return index }
        let next = index + direction
        if (0..<count).contains(next) { return next }
        if repeatMode == .all { return (next % count + count) % count }
        return nil
    }
}

func clock(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "0:00" }
    return "\(Int(value) / 60):\(String(format: "%02d", Int(value) % 60))"
}
