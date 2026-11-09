import Foundation
import CryptoKit

struct SearchReply: Decodable { var tracks: [Track]; var hasMore: Bool }
struct ResolveReply: Decodable { var path: String; var duration: Double; var title: String; var artist: String }
struct LyricsReply: Decodable { var syncedLyrics: String?; var plainLyrics: String?; var instrumental: Bool? }
struct HealthReply: Decodable { var version: String; var engine: String }

struct MusicAPI {
    var endpoint: String
    var token: String
    var base: URL {
        get throws {
            guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { throw AppError.message("Configure the music server in Settings") }
            if url.scheme == "http" {
                let host = url.host!.lowercased()
                let labels = host.split(separator: ".")
                let pieces = labels.compactMap { Int($0) }
                let ipv4 = labels.count == 4 && pieces.count == 4 && pieces.allSatisfy { (0...255).contains($0) }
                let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") ||
                    (ipv4 && (pieces[0] == 10 || (pieces[0] == 192 && pieces[1] == 168) || (pieces[0] == 172 && (16...31).contains(pieces[1]))))
                guard local else { throw AppError.message("Use HTTPS for a public music server") }
            }
            return url
        }
    }
    func request<T: Decodable>(_ route: String, query: [String: String] = [:]) async throws -> T {
        let root = try base
        var components = URLComponents(url: root.appendingPathComponent("v1/" + route), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!); request.timeoutInterval = route == "resolve" ? 120 : 60
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.message("Invalid server response") }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw AppError.message(message ?? "Server: HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func search(_ query: String, page: Int) async throws -> SearchReply { try await request("search", query: ["q": query, "page": String(page)]) }
    func lyrics(_ track: Track) async throws -> LyricsReply { try await request("lyrics", query: ["title": track.title, "artist": track.artist, "duration": String(Int(track.duration))]) }
    func audio(_ track: Track) async throws -> URL {
        if let file = track.file { return try Files.local(file) }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("verness-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data((endpoint + track.id).utf8)).map { String(format: "%02x", $0) }.joined()
        let target = cache.appendingPathComponent(digest + ".m4a")
        if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path); return target }
        let reply: ResolveReply = try await request("resolve", query: ["id": track.videoId ?? track.id.replacingOccurrences(of: "yt:", with: "")])
        let root = try base
        guard reply.path.hasPrefix("/v1/audio/"), let url = URL(string: reply.path, relativeTo: root)?.absoluteURL,
              url.host == root.host, url.port == root.port, url.scheme == root.scheme else { throw AppError.message("Invalid stream URL") }
        var request = URLRequest(url: url); request.timeoutInterval = 120
        _ = try await AudioDownloads.shared.download(request, to: target)
        try Task.checkCancellation()
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for file in files.sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) where file != target && total > 300_000_000 {
            total -= (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: file)
        }
        return target
    }
}
