import Foundation
import CryptoKit

enum FfmpegInstallerError: LocalizedError {
    case network(String)
    case checksumMismatch(expected: String, got: String)
    case extractionFailed(String)
    case codesignFailed(String)
    case filesystem(String)

    var errorDescription: String? {
        switch self {
        case .network(let m): return "Failed to download FFmpeg: \(m)"
        case .checksumMismatch(let exp, let got):
            return "Downloaded FFmpeg integrity check failed (expected \(exp.prefix(12))…, got \(got.prefix(12))…)."
        case .extractionFailed(let m): return "Could not unpack FFmpeg archive: \(m)"
        case .codesignFailed(let m): return "Could not finalize FFmpeg signature: \(m)"
        case .filesystem(let m): return "Filesystem error: \(m)"
        }
    }
}

struct FfmpegInstallProgress {
    var fraction: Double
    var message: String
}

enum FfmpegInstaller {
    static let downloadURL = URL(string: "https://www.osxexperts.net/ffmpeg81arm.zip")!
    static let expectedBinarySHA256 = "9a08d61f9328e8164ba560ee7a79958e357307fcfeea6fe626b7d66cdc287028"
    static let ffmpegVersion = "8.1-arm64"

    static func installedURL() -> URL? {
        let url = expectedInstallURL
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static func install(
        progress: @escaping @MainActor (FfmpegInstallProgress) -> Void
    ) async throws -> URL {
        let dest = expectedInstallURL
        let fm = FileManager.default

        try ensureParentDirectory(for: dest)

        await MainActor.run { progress(.init(fraction: 0, message: "Preparing download…")) }

        let tempZip = try await download(from: downloadURL) { fraction in
            // Download takes ~90% of the bar; remaining 10% is verify/extract/sign
            let scaled = 0.02 + fraction * 0.88
            Task { @MainActor in
                progress(.init(fraction: scaled, message: "Downloading FFmpeg… \(Int(fraction * 100))%"))
            }
        }
        defer { try? fm.removeItem(at: tempZip) }

        try Task.checkCancellation()

        let extractDir = fm.temporaryDirectory.appendingPathComponent("ffmpeg-install-\(UUID().uuidString)")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }

        await MainActor.run { progress(.init(fraction: 0.92, message: "Extracting…")) }
        try extractZip(zip: tempZip, into: extractDir)

        let extractedBinary = extractDir.appendingPathComponent("ffmpeg")
        guard fm.fileExists(atPath: extractedBinary.path) else {
            throw FfmpegInstallerError.extractionFailed("ffmpeg binary not found in archive")
        }

        await MainActor.run { progress(.init(fraction: 0.95, message: "Verifying integrity…")) }
        let hash = try sha256Hex(of: extractedBinary)
        guard hash == expectedBinarySHA256 else {
            throw FfmpegInstallerError.checksumMismatch(expected: expectedBinarySHA256, got: hash)
        }

        try Task.checkCancellation()

        await MainActor.run { progress(.init(fraction: 0.97, message: "Installing…")) }
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: extractedBinary, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        stripQuarantine(at: dest)
        try adhocCodesign(at: dest)

        await MainActor.run { progress(.init(fraction: 1.0, message: "Ready")) }
        return dest
    }

    private static var expectedInstallURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Video to GIF", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("ffmpeg")
    }

    private static func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw FfmpegInstallerError.filesystem("could not create \(parent.path): \(error.localizedDescription)")
        }
    }

    private static func download(
        from url: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let delegate = DownloadProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.completion = { result in
                    continuation.resume(with: result)
                }
                let task = session.downloadTask(with: url)
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.task?.cancel()
        }
    }

    private static func extractZip(zip: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zip.path, "-d", directory.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw FfmpegInstallerError.extractionFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FfmpegInstallerError.extractionFailed("unzip exited \(process.terminationStatus): \(err)")
        }
    }

    private static func sha256Hex(of file: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw FfmpegInstallerError.filesystem("could not read \(file.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20) // 1 MB
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stripQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func adhocCodesign(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw FfmpegInstallerError.codesignFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FfmpegInstallerError.codesignFailed("codesign exited \(process.terminationStatus): \(err)")
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: (Double) -> Void
    var completion: ((Result<URL, Error>) -> Void)?
    weak var task: URLSessionDownloadTask?
    private var persistedTempURL: URL?

    init(progress: @escaping (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progress(min(max(fraction, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // didFinishDownloadingTo's `location` is deleted as soon as this method returns,
        // so move it to a stable temp file we control.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg-download-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            persistedTempURL = stable
        } catch {
            completion?(.failure(FfmpegInstallerError.network("could not persist download: \(error.localizedDescription)")))
            completion = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { completion = nil }
        if let error = error {
            if let url = persistedTempURL { try? FileManager.default.removeItem(at: url) }
            completion?(.failure(FfmpegInstallerError.network(error.localizedDescription)))
            return
        }
        if let response = task.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            if let url = persistedTempURL { try? FileManager.default.removeItem(at: url) }
            completion?(.failure(FfmpegInstallerError.network("HTTP \(response.statusCode)")))
            return
        }
        if let url = persistedTempURL {
            completion?(.success(url))
        } else {
            completion?(.failure(FfmpegInstallerError.network("download finished without a file")))
        }
    }
}
