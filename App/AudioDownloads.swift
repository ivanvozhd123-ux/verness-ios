import Foundation
import UIKit

final class AudioDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = AudioDownloads()
    static let identifier = "app.verness.ios.audio"
    var eventsFinished: (() -> Void)?
    private let lock = NSLock()
    private var jobs: [Int: CheckedContinuation<URL, Error>] = [:]
    private var session: URLSession!
    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    static var folder: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("verness-audio", isDirectory: true) }
    func start() { _ = session }
    private final class Ticket: @unchecked Sendable {
        let lock = NSLock()
        var task: URLSessionTask?
        var cancelled = false
        func attach(_ task: URLSessionTask) { lock.lock(); self.task = task; let stop = cancelled; lock.unlock(); if stop { task.cancel() } }
        func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    }
    func download(_ request: URLRequest, to target: URL) async throws -> URL {
        let ticket = Ticket()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                task.taskDescription = target.lastPathComponent
                lock.lock(); jobs[task.taskIdentifier] = continuation; lock.unlock()
                ticket.attach(task)
                task.resume()
            }
        } onCancel: { ticket.cancel() }
    }
    private func finish(_ task: URLSessionTask, _ result: Result<URL, Error>) {
        lock.lock(); let continuation = jobs.removeValue(forKey: task.taskIdentifier); lock.unlock()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { throw AppError.message("Audio download failed") }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 100_000_000 else { throw AppError.message("Audio exceeds 100 MB") }
            guard let name = downloadTask.taskDescription, name.range(of: #"^[a-f0-9]{64}\.m4a$"#, options: .regularExpression) != nil else { throw AppError.message("Invalid cache filename") }
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let target = Self.folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                do { try FileManager.default.moveItem(at: location, to: target) }
                catch { if !FileManager.default.fileExists(atPath: target.path) { throw error } }
            }
            finish(downloadTask, .success(target))
        } catch { finish(downloadTask, .failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(task, .failure(error)) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { let completion = self.eventsFinished; self.eventsFinished = nil; completion?() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == AudioDownloads.identifier else { completionHandler(); return }
        AudioDownloads.shared.eventsFinished = completionHandler
        AudioDownloads.shared.start()
    }
}
