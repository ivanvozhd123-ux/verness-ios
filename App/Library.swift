import Foundation
import AVFoundation
import UIKit
import Security

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

enum Files {
    static var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("verness", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func local(_ name: String) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.contains("..") else { throw AppError.message("Invalid library path") }
        return root.appendingPathComponent(name)
    }
    static func read() throws -> LibraryData {
        let url = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryData() }
        return try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: url))
    }
    static func save(_ library: LibraryData) throws {
        try JSONEncoder().encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
    static func importAudio(_ url: URL) async throws -> Track {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID().uuidString
        let name = id + "." + (url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased())
        let target = try local(name)
        do {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: target) } catch { copyError = error }
            }
            if let error = coordinationError { throw error }
            if let error = copyError { throw error }
            let audio = try AVAudioFile(forReading: target)
            guard (1...2).contains(audio.processingFormat.channelCount), (8000...192000).contains(audio.processingFormat.sampleRate), audio.length <= Int64(UInt32.max) else {
                throw AppError.message("Use mono/stereo audio at 8–192 kHz within the player frame limit")
            }
            let asset = AVURLAsset(url: target)
            let duration = try await asset.load(.duration).seconds
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            var title = url.deletingPathExtension().lastPathComponent, artist = "Unknown artist", cover: String?
            for item in metadata {
                if item.commonKey == .commonKeyTitle, let value = try? await item.load(.stringValue) { title = value }
                if item.commonKey == .commonKeyArtist, let value = try? await item.load(.stringValue) { artist = value }
                if item.commonKey == .commonKeyArtwork, let bytes = try? await item.load(.dataValue), bytes.count <= 8_000_000,
                   let image = UIImage(data: bytes), let data = thumbnail(image) {
                    let filename = id + ".jpg"; try data.write(to: local(filename), options: .atomic); cover = filename
                }
            }
            return Track(id: id, title: title, artist: artist, duration: duration.isFinite ? duration : 0, cover: cover, file: name)
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
    static func thumbnail(_ image: UIImage) -> Data? {
        let factor = min(1, 512 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
    }
}

enum Secrets {
    static let service = "app.verness.ios"
    static func token() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "api", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func setToken(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api"]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AppError.message("Could not save API key") }
    }
}
