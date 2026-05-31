import Foundation
import AppKit

struct ExtractionResult {
    let outputName: String
    let destinationPath: String
    let fullPath: String
}

enum ExtractionState {
    case idle
    case extracting(filename: String, progress: Double, currentFile: String)
    case success(ExtractionResult)
    case failure(String)
}

private enum ExtractionMethod {
    case process(tool: String, args: [String], outputName: String)
    case openWithApp(appURL: URL)
}

@MainActor
final class Extractor: ObservableObject {
    @Published var state: ExtractionState = .idle

    func reset() { state = .idle }
    func setFailure(_ msg: String) { state = .failure(msg) }

    func extract(url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        state = .extracting(filename: resolved.lastPathComponent, progress: 0, currentFile: "")

        Task.detached(priority: .userInitiated) {
            do {
                let result = try await Extractor.performExtraction(url: resolved) { progress, file in
                    await MainActor.run {
                        self.state = .extracting(
                            filename: resolved.lastPathComponent,
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

    private static func performExtraction(
        url: URL,
        onProgress: @escaping (Double, String) async -> Void
    ) async throws -> ExtractionResult {

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ExtractionError.processFailed("File not found: \(url.path)")
        }

        let sourceDir = url.deletingLastPathComponent()
        let filename  = url.lastPathComponent
        let ext       = url.pathExtension.lowercased()
        let stem      = url.deletingPathExtension().lastPathComponent

        let method = try resolveMethod(filePath: url.path, ext: ext,
                                       nameWithoutExt: stem, sourceDir: sourceDir)

        switch method {

        case .openWithApp(let appURL):
            await MainActor.run {
                NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            return ExtractionResult(outputName: filename,
                                    destinationPath: sourceDir.path,
                                    fullPath: sourceDir.path)

        case .process(let tool, let args, let outputName):
            // 1. Count total entries so we can show real progress
            let total = await countEntries(url: url, ext: ext)

            // 2. Run the actual extraction, streaming stdout for progress
            let (exitCode, errMsg) = try await runWithProgress(
                tool: tool, args: args, workingDir: sourceDir,
                total: total, onProgress: onProgress
            )

            guard exitCode == 0 else {
                throw ExtractionError.processFailed(errMsg.isEmpty
                    ? "Exit code \(exitCode)" : errMsg)
            }

            let outPath = sourceDir.appendingPathComponent(outputName).path
            let finalPath = fm.fileExists(atPath: outPath) ? outPath : sourceDir.path

            return ExtractionResult(
                outputName: fm.fileExists(atPath: outPath) ? outputName : filename,
                destinationPath: sourceDir.path,
                fullPath: finalPath
            )
        }
    }

    // MARK: - Entry counting (for progress denominator)

    private static func countEntries(url: URL, ext: String) async -> Int {
        // Use list-only commands to count files without extracting
        let (tool, args): (String, [String])
        switch ext {
        case "zip":
            (tool, args) = ("/usr/bin/unzip", ["-Z1", url.path])
        case "tar", "tgz", "gz", "bz2", "xz":
            let flag: String
            switch ext {
            case "tgz", "gz": flag = "-tzf"
            case "bz2":       flag = "-tjf"
            case "xz":        flag = "-tJf"
            default:          flag = "-tf"
            }
            (tool, args) = ("/usr/bin/tar", [flag, url.path])
        default:
            return 0  // unknown — indeterminate progress
        }

        guard let result = try? await runSilent(tool: tool, args: args) else { return 0 }
        let count = result.components(separatedBy: "\n")
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return false }
                // For unzip -Z1, skip directory entries (end with /)
                if ext == "zip" { return !t.hasSuffix("/") }
                return true
            }
            .count
        return max(count, 1)
    }

    // MARK: - Process runners

    /// Run a process and stream stdout lines to the progress callback.
    private static func runWithProgress(
        tool: String,
        args: [String],
        workingDir: URL,
        total: Int,
        onProgress: @escaping (Double, String) async -> Void
    ) async throws -> (Int32, String) {

        // For tar we add -v to get per-file output on stdout.
        // unzip -o already prints "extracting: ..." per file — do NOT add -v
        // (unzip -v means "list mode", which skips actual extraction).
        var verboseArgs = args
        let toolName = URL(fileURLWithPath: tool).lastPathComponent
        if toolName == "tar" && !verboseArgs.contains("-v") {
            if !verboseArgs.isEmpty {
                verboseArgs[0] = verboseArgs[0] + "v"
            }
        }
        // gunzip / bzip2 / xz: single-file, no per-file output — indeterminate bar

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
            var leftover = ""   // partial line buffer

            // Read stdout asynchronously line by line
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                let text = leftover + (String(data: chunk, encoding: .utf8) ?? "")
                var lines = text.components(separatedBy: "\n")
                leftover = lines.removeLast()   // last element may be incomplete

                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Skip unzip header/directory lines — they don't count as file progress
                    if toolName == "unzip" {
                        if trimmed.hasPrefix("Archive:") || trimmed.hasPrefix("creating:") { continue }
                    }
                    processed += 1
                    let fraction = total > 0
                        ? min(Double(processed) / Double(total), 0.99)
                        : -1   // -1 = indeterminate
                    let displayName = Self.extractFilename(from: line, tool: toolName)
                    Task {
                        await onProgress(fraction < 0 ? 0.5 : fraction, displayName)
                    }
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

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Parse a verbose output line to get just the filename portion.
    private nonisolated static func extractFilename(from line: String, tool: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if tool == "unzip" {
            // Lines look like:
            //   "  extracting: /full/path/to/file.txt  "
            //   "  inflating: /full/path/to/file.txt  "
            //   "   creating: /full/path/to/dir/"
            // Strip the verb prefix, then return just the last path component.
            for prefix in ["extracting:", "inflating:", "creating:", "linking:"] {
                if trimmed.hasPrefix(prefix) {
                    let rest = trimmed.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespaces)
                    return URL(fileURLWithPath: rest).lastPathComponent
                }
            }
            // Fallback: anything after ": "
            if let range = trimmed.range(of: ": ") {
                let rest = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return URL(fileURLWithPath: rest).lastPathComponent
            }
        }
        // tar -v just prints the filename directly
        return trimmed
    }

    /// Run a process silently and return all stdout as a string.
    private static func runSilent(tool: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = Pipe()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - Method resolution (unchanged logic)

    private static func resolveMethod(
        filePath: String, ext: String,
        nameWithoutExt: String, sourceDir: URL
    ) throws -> ExtractionMethod {

        switch ext {
        case "zip":
            let outputDir = sourceDir.appendingPathComponent(nameWithoutExt).path
            return .process(tool: "/usr/bin/unzip",
                            args: ["-o", filePath, "-d", outputDir],
                            outputName: nameWithoutExt)

        case "gz":
            if nameWithoutExt.lowercased().hasSuffix(".tar") {
                let base = String(nameWithoutExt.dropLast(4))
                return .process(tool: "/usr/bin/tar",
                                args: ["-xzf", filePath, "-C", sourceDir.path],
                                outputName: base)
            }
            return .process(tool: "/usr/bin/gunzip",
                            args: ["-f", filePath], outputName: nameWithoutExt)

        case "tgz":
            return .process(tool: "/usr/bin/tar",
                            args: ["-xzf", filePath, "-C", sourceDir.path],
                            outputName: nameWithoutExt)

        case "tar":
            return .process(tool: "/usr/bin/tar",
                            args: ["-xf", filePath, "-C", sourceDir.path],
                            outputName: nameWithoutExt)

        case "bz2":
            if nameWithoutExt.lowercased().hasSuffix(".tar") {
                let base = String(nameWithoutExt.dropLast(4))
                return .process(tool: "/usr/bin/tar",
                                args: ["-xjf", filePath, "-C", sourceDir.path],
                                outputName: base)
            }
            return .process(tool: "/usr/bin/bzip2",
                            args: ["-dk", filePath], outputName: nameWithoutExt)

        case "xz":
            if nameWithoutExt.lowercased().hasSuffix(".tar") {
                let base = String(nameWithoutExt.dropLast(4))
                return .process(tool: "/usr/bin/tar",
                                args: ["-xJf", filePath, "-C", sourceDir.path],
                                outputName: base)
            }
            let xz = findExecutable(names: ["xz"],
                                    paths: ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"])
            guard let tool = xz else {
                throw ExtractionError.toolNotFound("xz not installed. Run: brew install xz")
            }
            return .process(tool: tool, args: ["-dk", filePath], outputName: nameWithoutExt)

        case "7z":
            let sz = findExecutable(names: ["7z","7za","7zz"],
                                    paths: ["/usr/local/bin","/opt/homebrew/bin","/usr/bin"])
            guard let tool = sz else {
                throw ExtractionError.toolNotFound("7z not installed. Run: brew install p7zip")
            }
            let outputDir = sourceDir.appendingPathComponent(nameWithoutExt).path
            return .process(tool: tool,
                            args: ["x", filePath, "-o\(outputDir)", "-y"],
                            outputName: nameWithoutExt)

        case "rar":
            if let unrar = findExecutable(names: ["unrar","rar"],
                                          paths: ["/usr/local/bin","/opt/homebrew/bin","/usr/bin"]) {
                let outputDir = sourceDir.appendingPathComponent(nameWithoutExt).path
                return .process(tool: unrar,
                                args: ["x", "-y", filePath, outputDir + "/"],
                                outputName: nameWithoutExt)
            }
            if let unar = findExecutable(names: ["unar"],
                                         paths: ["/usr/local/bin","/opt/homebrew/bin","/usr/bin"]) {
                return .process(tool: unar,
                                args: ["-o", sourceDir.path, "-f", filePath],
                                outputName: nameWithoutExt)
            }
            let unarchiverPath = "/Applications/The Unarchiver.app"
            if FileManager.default.fileExists(atPath: unarchiverPath) {
                return .openWithApp(appURL: URL(fileURLWithPath: unarchiverPath))
            }
            let archiveUtil = "/System/Library/CoreServices/Applications/Archive Utility.app"
            if FileManager.default.fileExists(atPath: archiveUtil) {
                return .openWithApp(appURL: URL(fileURLWithPath: archiveUtil))
            }
            throw ExtractionError.toolNotFound(
                "No RAR tool found. Install The Unarchiver from the App Store, or run: brew install unrar")

        case "cpgz":
            let outputDir = sourceDir.appendingPathComponent(nameWithoutExt).path
            return .process(tool: "/usr/bin/ditto",
                            args: ["-xk", filePath, outputDir], outputName: nameWithoutExt)

        default:
            let outputDir = sourceDir.appendingPathComponent(nameWithoutExt).path
            return .process(tool: "/usr/bin/ditto",
                            args: ["-xk", filePath, outputDir], outputName: nameWithoutExt)
        }
    }

    private static func findExecutable(names: [String], paths: [String]) -> String? {
        for name in names {
            for path in paths {
                let full = "\(path)/\(name)"
                if FileManager.default.isExecutableFile(atPath: full) { return full }
            }
        }
        return nil
    }
}

enum ExtractionError: LocalizedError {
    case toolNotFound(String)
    case processFailed(String)
    var errorDescription: String? {
        switch self {
        case .toolNotFound(let m): return m
        case .processFailed(let m): return m
        }
    }
}
