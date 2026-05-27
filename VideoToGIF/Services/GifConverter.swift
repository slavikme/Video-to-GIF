import Foundation
import Combine

/// Represents an error that occurred during GIF conversion
struct ConversionError: Error {
    let message: String      // User-friendly message
    let fullOutput: String   // Complete FFmpeg stderr for debugging
}

/// Represents the current state of a conversion
struct ConversionProgress {
    let percentage: Double   // 0.0 to 1.0
    let currentTime: Double  // Current time in seconds
    let totalDuration: Double // Total duration in seconds
    let statusMessage: String

    init(percentage: Double, currentTime: Double = 0, totalDuration: Double = 0, statusMessage: String = "Converting to GIF…") {
        self.percentage = percentage
        self.currentTime = currentTime
        self.totalDuration = totalDuration
        self.statusMessage = statusMessage
    }
}

/// Represents video metadata extracted from FFmpeg
struct VideoMetadata {
    let width: Int
    let height: Int
    let frameRate: Double
    let duration: Double
}

/// Service responsible for converting videos to GIFs using FFmpeg
class GifConverter: ObservableObject {
    /// Published log output for debug window
    @Published var debugOutput: [DebugLogEntry] = []
    
    /// Whether debug mode is enabled
    @Published var isDebugEnabled: Bool = false
    
    /// Current running process (for cancellation)
    private var currentProcess: Process?
    
    /// Cancellation flag
    private var isCancelled = false
    
    /// Represents a single debug log entry
    struct DebugLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        
        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
        }
    }
    
    /// Locate an already-installed ffmpeg without triggering a download.
    /// Order: the installer's cache path, then dev fallbacks (Homebrew).
    private func locallyAvailableFfmpegPath() -> String? {
        if let url = FfmpegInstaller.installedURL() {
            return url.path
        }
        for path in ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Return a usable ffmpeg path, downloading + installing it first if needed.
    /// `progressHandler` receives install progress updates only when a download is required.
    private func ensureFfmpeg(
        progressHandler: @escaping (ConversionProgress) -> Void
    ) async throws -> String {
        if let existing = locallyAvailableFfmpegPath() {
            return existing
        }
        addDebugLog("FFmpeg not found locally — downloading bundled build…")
        do {
            let url = try await FfmpegInstaller.install { [weak self] update in
                self?.addDebugLog(update.message)
                progressHandler(ConversionProgress(
                    percentage: update.fraction,
                    statusMessage: update.message
                ))
            }
            addDebugLog("FFmpeg installed at \(url.path)")
            return url.path
        } catch let error as FfmpegInstallerError {
            throw ConversionError(
                message: error.errorDescription ?? "FFmpeg installation failed.",
                fullOutput: "FfmpegInstaller error: \(error)"
            )
        }
    }
    
    /// Probe video to get its metadata (width, height, frame rate)
    /// - Parameters:
    ///   - inputURL: URL of the video file
    ///   - ffmpegPath: Resolved ffmpeg binary path (caller is responsible for ensuring it exists)
    /// - Returns: VideoMetadata containing the video's properties
    func probeVideo(at inputURL: URL, ffmpegPath ffmpeg: String) async throws -> VideoMetadata {
        addDebugLog("Probing video metadata...")
        
        // Use ffmpeg -i to get video info (outputs to stderr)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-i", inputURL.path]
        
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stderrData, encoding: .utf8) ?? ""
        
        // Parse video stream info
        // Example: "Stream #0:0: Video: h264, yuv420p, 996x712, 57.51 fps, 60 tbr"
        // Or: "Stream #0:0[0x1](und): Video: h264 (Main) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 996x712, 2462 kb/s, 57.51 fps, 60 tbr"
        
        var width: Int = 996  // Default fallback
        var height: Int = 712
        var frameRate: Double = 25.0
        var duration: Double = 0
        
        // Parse duration
        if let dur = parseDuration(from: output) {
            duration = dur
            addDebugLog("Duration: \(String(format: "%.2f", dur)) seconds")
        }
        
        // Parse resolution - look for pattern like "996x712" or "1920x1080"
        let resolutionPattern = #"(\d{2,5})x(\d{2,5})"#
        if let regex = try? NSRegularExpression(pattern: resolutionPattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let widthRange = Range(match.range(at: 1), in: output),
           let heightRange = Range(match.range(at: 2), in: output) {
            width = Int(output[widthRange]) ?? width
            height = Int(output[heightRange]) ?? height
            addDebugLog("Resolution: \(width)x\(height)")
        }
        
        // Parse frame rate - look for patterns like "57.51 fps" or "30 fps" or "29.97 fps"
        let fpsPattern = #"(\d+(?:\.\d+)?)\s*fps"#
        if let regex = try? NSRegularExpression(pattern: fpsPattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let fpsRange = Range(match.range(at: 1), in: output) {
            frameRate = Double(output[fpsRange]) ?? frameRate
            addDebugLog("Frame rate: \(String(format: "%.2f", frameRate)) fps")
        }
        
        return VideoMetadata(width: width, height: height, frameRate: frameRate, duration: duration)
    }
    
    /// Convert a video to GIF using the original video's frame rate and resolution
    /// - Parameters:
    ///   - inputURL: URL of the input video
    ///   - outputURL: URL where the GIF should be saved
    ///   - progressHandler: Callback for progress updates
    /// - Returns: The URL of the created GIF
    @MainActor
    func convert(
        input inputURL: URL,
        output outputURL: URL,
        progressHandler: @escaping (ConversionProgress) -> Void
    ) async throws -> URL {
        isCancelled = false
        debugOutput = []

        let ffmpeg = try await ensureFfmpeg(progressHandler: progressHandler)

        // Reset progress to 0 before the conversion phase, with a fresh status message.
        progressHandler(ConversionProgress(percentage: 0, statusMessage: "Converting to GIF…"))

        addDebugLog("Starting conversion...")
        addDebugLog("Input: \(inputURL.path)")
        addDebugLog("Output: \(outputURL.path)")

        // Probe video to get original properties
        let metadata: VideoMetadata
        do {
            metadata = try await probeVideo(at: inputURL, ffmpegPath: ffmpeg)
        } catch {
            // If probing fails, use sensible defaults
            addDebugLog("Warning: Could not probe video metadata, using defaults")
            metadata = VideoMetadata(width: 996, height: 712, frameRate: 25, duration: 0)
        }
        
        // Calculate frame rate and width based on settings
        let settings = SettingsManager.shared
        let fps = settings.calculateFrameRate(from: metadata.frameRate)
        let width = settings.calculateWidth(from: metadata.width)
        
        addDebugLog("Original: \(metadata.width)x\(metadata.height) @ \(String(format: "%.2f", metadata.frameRate)) fps")
        addDebugLog("Output: \(width)px width @ \(fps) fps")
        
        // Build the filter string for high-quality GIF with palette
        // Using original width and frame rate from the source video
        let filter = "fps=\(fps),scale=\(width):-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
        
        let arguments = [
            "-i", inputURL.path,
            "-vf", filter,
            "-y",  // Overwrite output
            outputURL.path
        ]
        
        addDebugLog("Command: \(ffmpeg) \(arguments.joined(separator: " "))")
        
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe() // Discard stdout
            
            var stderrData = Data()
            var totalDuration: Double = metadata.duration
            
            // Read stderr asynchronously
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                
                stderrData.append(data)
                
                if let output = String(data: data, encoding: .utf8) {
                    // Parse for duration if we don't have it yet
                    if totalDuration == 0, let duration = self?.parseDuration(from: output) {
                        totalDuration = duration
                    }
                    
                    // Parse for progress
                    if let currentTime = self?.parseCurrentTime(from: output), totalDuration > 0 {
                        let percentage = min(currentTime / totalDuration, 1.0)
                        let progress = ConversionProgress(
                            percentage: percentage,
                            currentTime: currentTime,
                            totalDuration: totalDuration
                        )
                        DispatchQueue.main.async {
                            progressHandler(progress)
                        }
                    }
                    
                    // Add to debug log
                    for line in output.components(separatedBy: .newlines) where !line.isEmpty {
                        DispatchQueue.main.async {
                            self?.addDebugLog(line)
                        }
                    }
                }
            }
            
            process.terminationHandler = { [weak self] process in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                
                let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""
                
                DispatchQueue.main.async {
                    if self?.isCancelled == true {
                        self?.addDebugLog("Conversion cancelled by user.")
                        continuation.resume(throwing: ConversionError(
                            message: "Conversion was cancelled.",
                            fullOutput: stderrOutput
                        ))
                        return
                    }
                    
                    if process.terminationStatus == 0 {
                        self?.addDebugLog("Conversion completed successfully!")
                        continuation.resume(returning: outputURL)
                    } else {
                        let errorMessage = self?.parseErrorMessage(from: stderrOutput) ?? "Unknown error occurred"
                        self?.addDebugLog("Conversion failed: \(errorMessage)")
                        continuation.resume(throwing: ConversionError(
                            message: errorMessage,
                            fullOutput: stderrOutput
                        ))
                    }
                }
            }
            
            currentProcess = process
            
            do {
                try process.run()
            } catch {
                addDebugLog("Failed to start FFmpeg: \(error.localizedDescription)")
                continuation.resume(throwing: ConversionError(
                    message: "Failed to start FFmpeg: \(error.localizedDescription)",
                    fullOutput: error.localizedDescription
                ))
            }
        }
    }
    
    /// Cancel the current conversion
    func cancel() {
        isCancelled = true
        currentProcess?.terminate()
        currentProcess = nil
    }
    
    /// Parse total duration from FFmpeg output
    /// Example: "Duration: 00:00:09.61, start: 0.000000, bitrate: 2682 kb/s"
    private func parseDuration(from output: String) -> Double? {
        let pattern = #"Duration:\s*(\d{2}):(\d{2}):(\d{2}\.\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) else {
            return nil
        }
        
        guard let hoursRange = Range(match.range(at: 1), in: output),
              let minutesRange = Range(match.range(at: 2), in: output),
              let secondsRange = Range(match.range(at: 3), in: output) else {
            return nil
        }
        
        let hours = Double(output[hoursRange]) ?? 0
        let minutes = Double(output[minutesRange]) ?? 0
        let seconds = Double(output[secondsRange]) ?? 0
        
        return hours * 3600 + minutes * 60 + seconds
    }
    
    /// Parse current time from FFmpeg progress output
    /// Example: "frame=  240 fps= 54 q=-0.0 Lsize=    4671KiB time=00:00:09.60"
    private func parseCurrentTime(from output: String) -> Double? {
        let pattern = #"time=(\d{2}):(\d{2}):(\d{2}\.\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        
        // Find the last match (most recent progress)
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard let match = matches.last else { return nil }
        
        guard let hoursRange = Range(match.range(at: 1), in: output),
              let minutesRange = Range(match.range(at: 2), in: output),
              let secondsRange = Range(match.range(at: 3), in: output) else {
            return nil
        }
        
        let hours = Double(output[hoursRange]) ?? 0
        let minutes = Double(output[minutesRange]) ?? 0
        let seconds = Double(output[secondsRange]) ?? 0
        
        return hours * 3600 + minutes * 60 + seconds
    }
    
    /// Parse user-friendly error message from FFmpeg output
    private func parseErrorMessage(from output: String) -> String {
        // Common error patterns
        if output.contains("No such file or directory") {
            return "Input file not found."
        }
        if output.contains("Invalid data found") {
            return "The input file appears to be corrupted or in an unsupported format."
        }
        if output.contains("Permission denied") {
            return "Permission denied. Cannot access the file."
        }
        if output.contains("already exists. Overwrite?") {
            return "Output file already exists."
        }
        
        // Try to extract the last error line
        let lines = output.components(separatedBy: .newlines)
        for line in lines.reversed() {
            if line.lowercased().contains("error") {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        
        return "Conversion failed. Check the details for more information."
    }
    
    /// Add an entry to the debug log
    private func addDebugLog(_ message: String) {
        if isDebugEnabled {
            let entry = DebugLogEntry(timestamp: Date(), message: message)
            DispatchQueue.main.async {
                self.debugOutput.append(entry)
            }
        }
    }
    
    /// Clear the debug log
    func clearDebugLog() {
        debugOutput = []
    }
}
