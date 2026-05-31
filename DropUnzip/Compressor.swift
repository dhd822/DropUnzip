import Foundation
import AppKit

enum CompressFormat: String, CaseIterable, Identifiable {
    case zip    = "zip"
    case tarGz  = "tar.gz"
    case tarBz2 = "tar.bz2"
    case tarXz  = "tar.xz"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zip:    return ".zip"
        case .tarGz:  return ".tar.gz"
        case .tarBz2: return ".tar.bz2"
        case .tarXz:  return ".tar.xz"
        }
    }

    var icon: String {
        switch self {
        case .zip:    return "doc.zipper"
        default:      return "archivebox"
        }
    }

    var description: String {
        switch self {
        case .zip:    return "Best compatibility"
        case .tarGz:  return "Fast, good compression"
        case .tarBz2: return "Smaller, slower"
        case .tarXz:  return "Best compression"
        }
    }
}

struct CompressionResult {
    let outputName: String
    let outputPath: String
    let destinationPath: String
}

enum CompressionState {
    case idle
    case pickingFormat(urls: [URL])
    case compressing(filename: String, progress: Double, currentFile: String)
    case success(CompressionResult)
    case failure(String)
}

@MainActor
final class Compressor: ObservableObject {
    @Published var state: CompressionState = .idle

    func reset() { state = .idle }
    func setFailure(_ msg: String) { state = .failure(msg) }

    func promptFormat(for urls: [URL]) {
        state = .pickingFormat(urls: urls)
    }

    func compress(urls: [URL], format: CompressFormat) {
        let baseName   = urls.first?.deletingPathExtension().lastPathComponent ?? "archive"
        let outputDir  = urls.first?.deletingLastPathComponent()
                         ?? URL(fileURLWithPath: NSHomeDirectory())
        let outputName = "\(baseName).\(format.rawValue)"
        let outputPath = outputDir.appendingPathComponent(outputName).path

        state = .compressing(filename: outputName, progress: 0, currentFile: "")

        Task.detached(priority: .userInitiated) {
            do {
                let result = try await Compressor.performCompression(
                    urls: urls, format: format,
                    outputPath: outputPath, outputDir: outputDir
                ) { progress, file in
                    await MainActor.run {
                        self.state = .compressing(
                            filename: outputName,
                            progress: progress,
                            currentFile: file
                        )
                    }
                }
                await MainActor.run { self.state = .success(result) }
            } catch {
                await MainActor.run { self.state = .failure(error.localizedDescription) }
            }
        }
    }

    // MARK: - Core

    private static func performCompression(
        urls: [URL],
        format: CompressFormat,
        outputPath: String,
        outputDir: URL,
        onProgress: @escaping (Double, String) async -> Void
    ) async throws -> CompressionResult {

        try? FileManager.default.removeItem(atPath: outputPath)

        // Count total files across all inputs for progress denominator
        let total = await countFiles(in: urls)

        let names = urls.map { $0.lastPathComponent }

        switch format {
        case .zip:
            // zip prints "  adding: filename" per file on stdout
            let args = ["-r", outputPath] + names
            let (code, err) = try await runWithProgress(
                tool: "/usr/bin/zip", args: args, workingDir: outputDir,
                total: total, toolName: "zip", onProgress: onProgress)
            guard code == 0 else { throw CompressionError.failed(err) }

        case .tarGz:
            let args = ["-czf", outputPath] + names
            let (code, err) = try await runWithProgress(
                tool: "/usr/bin/tar", args: args, workingDir: outputDir,
                total: total, toolName: "tar", onProgress: onProgress)
            guard code == 0 else { throw CompressionError.failed(err) }

        case .tarBz2:
            let args = ["-cjf", outputPath] + names
            let (code, err) = try await runWithProgress(
                tool: "/usr/bin/tar", args: args, workingDir: outputDir,
                total: total, toolName: "tar", onProgress: onProgress)
            guard code == 0 else { throw CompressionError.failed(err) }

        case .tarXz:
            let args = ["-cJf", outputPath] + names
            let (code, err) = try await runWithProgress(
                tool: "/usr/bin/tar", args: args, workingDir: outputDir,
                total: total, toolName: "tar", onProgress: onProgress)
            guard code == 0 else { throw CompressionError.failed(err) }
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw CompressionError.failed("Output file was not created.")
        }

        return CompressionResult(
            outputName: URL(fileURLWithPath: outputPath).lastPathComponent,
            outputPath: outputPath,
            destinationPath: outputDir.path
        )
    }

    // MARK: - File counting

    /// Recursively count all files in the given URLs (for progress denominator).
    private static func countFiles(in urls: [URL]) async -> Int {
        var count = 0
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if let enumerator = fm.enumerator(at: url,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles]) {
                        for case let fileURL as URL in enumerator {
                            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                                count += 1
                            }
                        }
                    }
                } else {
                    count += 1
                }
            }
        }
        return max(count, 1)
    }

    // MARK: - Process runner with progress streaming

    private static func runWithProgress(
        tool: String,
        args: [String],
        workingDir: URL,
        total: Int,
        toolName: String,
        onProgress: @escaping (Double, String) async -> Void
    ) async throws -> (Int32, String) {

        // Inject verbose flag so we get per-file output
        var verboseArgs = args
        if toolName == "tar", let first = verboseArgs.first {
            verboseArgs[0] = first + "v"   // e.g. -czf → -czvf
        }
        // zip already prints per-file output without a flag

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = verboseArgs
            process.currentDirectoryURL = workingDir

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            var processed = 0
            var stderrData = Data()
            var leftover = ""

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                let text = leftover + (String(data: chunk, encoding: .utf8) ?? "")
                var lines = text.components(separatedBy: "\n")
                leftover = lines.removeLast()

                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    processed += 1
                    let fraction = min(Double(processed) / Double(total), 0.99)
                    let displayName = Self.extractFilename(from: line, tool: toolName)
                    Task { await onProgress(fraction, displayName) }
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrData.append(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let errMsg = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (proc.terminationStatus, errMsg))
            }

            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private nonisolated static func extractFilename(from line: String, tool: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        if tool == "zip" {
            // "  adding: path/to/file (deflated 42%)"
            if t.hasPrefix("adding:") {
                let after = t.dropFirst("adding:".count).trimmingCharacters(in: .whitespaces)
                // strip trailing "(deflated …)" or "(stored)"
                if let paren = after.firstIndex(of: "(") {
                    return String(after[..<paren]).trimmingCharacters(in: .whitespaces)
                }
                return String(after)
            }
        }
        return t
    }
}

enum CompressionError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let m): return m.isEmpty ? "Compression failed." : m }
    }
}
