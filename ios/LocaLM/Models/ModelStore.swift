import CryptoKit
import Foundation
import UIKit

/// Downloads, verifies, and locates model files in Documents/Models
/// (visible in the Files app, excluded from iCloud backup).
@MainActor
final class ModelStore: NSObject, ObservableObject {
    enum DownloadState: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case verifying
        case failed(String)
    }

    @Published private(set) var states: [String: DownloadState] = [:]
    @Published private(set) var installed: Set<String> = []

    private var session: URLSession!
    private var tasks: [Int: ModelEntry] = [:]          // taskIdentifier -> entry
    private var running: [String: URLSessionDownloadTask] = [:]
    private var completions: [String: (Result<URL, Error>) -> Void] = [:]

    static var modelsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        refresh()
    }

    func path(for entry: ModelEntry) -> URL {
        Self.modelsDirectory.appendingPathComponent(entry.fileName)
    }

    func state(for entry: ModelEntry) -> DownloadState {
        states[entry.id] ?? .idle
    }

    /// A file counts as installed when it exists with the exact expected size.
    /// (The SHA-256 is checked once, right after download.)
    func refresh() {
        var found = Set<String>()
        for entry in ModelCatalog.entries {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path(for: entry).path)
            if let size = attrs?[.size] as? Int64, size == entry.sizeBytes { found.insert(entry.id) }
        }
        installed = found
    }

    func download(_ entry: ModelEntry) async throws -> URL {
        if installed.contains(entry.id) { return path(for: entry) }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        let tempURL: URL
        do {
            tempURL = try await withCheckedThrowingContinuation { cont in
                completions[entry.id] = { cont.resume(with: $0) }
                states[entry.id] = .downloading(received: 0, total: entry.sizeBytes)
                let task = session.downloadTask(with: entry.url)
                tasks[task.taskIdentifier] = entry
                running[entry.id] = task
                task.resume()
            }
            running[entry.id] = nil
        } catch {
            running[entry.id] = nil
            states[entry.id] = .failed(error.localizedDescription)
            throw error
        }

        states[entry.id] = .verifying
        let destination = path(for: entry)
        do {
            try await Self.verify(file: tempURL, expectedSize: entry.sizeBytes, sha256: entry.sha256)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            states[entry.id] = .failed(error.localizedDescription)
            throw error
        }
        states[entry.id] = .idle
        refresh()
        return destination
    }

    func cancelDownload(_ entry: ModelEntry) {
        running[entry.id]?.cancel()
    }

    func delete(_ entry: ModelEntry) {
        try? FileManager.default.removeItem(at: path(for: entry))
        refresh()
    }

    struct VerificationError: LocalizedError {
        var errorDescription: String?
    }

    /// Size, GGUF magic, and SHA-256, computed off the main thread in 8 MB chunks.
    nonisolated static func verify(file: URL, expectedSize: Int64, sha256 expected: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attrs[.size] as? Int64) ?? -1
            guard size == expectedSize else {
                throw VerificationError(errorDescription: "Download incomplete (\(size) of \(expectedSize) bytes).")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard let magic = try handle.read(upToCount: 4), magic == Data("GGUF".utf8) else {
                throw VerificationError(errorDescription: "File is not a GGUF model.")
            }
            try handle.seek(toOffset: 0)
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == expected else {
                throw VerificationError(errorDescription: "Checksum mismatch; the file is corrupted.")
            }
        }.value
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let entry = tasks[downloadTask.taskIdentifier] else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : entry.sizeBytes
            states[entry.id] = .downloading(received: totalBytesWritten, total: total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns, so move it synchronously.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        let moveResult: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveResult = .failure(VerificationError(errorDescription: "Server returned HTTP \(http.statusCode)."))
        } else {
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                moveResult = .success(kept)
            } catch {
                moveResult = .failure(error)
            }
        }
        MainActor.assumeIsolated {
            guard let entry = tasks.removeValue(forKey: downloadTask.taskIdentifier) else { return }
            completions.removeValue(forKey: entry.id)?(moveResult)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            guard let entry = tasks.removeValue(forKey: task.taskIdentifier) else { return }
            states[entry.id] = .failed(error.localizedDescription)
            completions.removeValue(forKey: entry.id)?(.failure(error))
        }
    }
}
