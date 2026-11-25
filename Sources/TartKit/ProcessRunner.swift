import Foundation

/// Result of a finished CLI invocation.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessError: LocalizedError, Sendable {
    case nonZeroExit(command: String, code: Int32, stderr: String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .nonZeroExit(command, code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` failed (exit \(code))" + (detail.isEmpty ? "" : ": \(detail)")
        case let .launchFailed(message):
            return "Could not launch process: \(message)"
        }
    }
}

/// Thin async wrapper around Foundation.Process.
public enum ProcessRunner {

    /// Runs a command to completion and collects its output.
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: String? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Read pipes concurrently so large outputs don't block the child.
            let outBuffer = DataBuffer()
            let errBuffer = DataBuffer()
            outPipe.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: outBuffer.string,
                    stderr: errBuffer.string
                ))
            }

            let inPipe: Pipe? = stdin == nil ? nil : Pipe()
            if let inPipe { process.standardInput = inPipe }

            do {
                try process.run()
                if let inPipe, let stdin {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
            } catch {
                continuation.resume(throwing: ProcessError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Runs a command and streams each output line (stdout and stderr merged) as it arrives.
    /// Used for long operations like `tart pull` / `tart push` that print progress.
    public static func stream(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let lineSplitter = LineSplitter { continuation.yield($0) }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                lineSplitter.feed(handle.availableData)
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                lineSplitter.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                lineSplitter.flush()
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
                    continuation.finish(throwing: ProcessError.nonZeroExit(
                        command: command,
                        code: proc.terminationStatus,
                        stderr: lineSplitter.lastLines.joined(separator: "\n")
                    ))
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ProcessError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Launches a long-lived process (e.g. `tart run`) without waiting for it.
    /// The returned Process can be observed for termination.
    public static func launchDetached(
        _ executable: URL,
        arguments: [String],
        logFile: URL? = nil,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let logFile {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: logFile)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
        return process
    }
}

// MARK: - Helpers

private final class DataBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Splits a byte stream into lines. Treats `\r` as a line break too,
/// since progress bars redraw with carriage returns.
private final class LineSplitter: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let emit: (String) -> Void
    private(set) var lastLines: [String] = []

    init(emit: @escaping (String) -> Void) { self.emit = emit }

    func feed(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<idx]
            pending.removeSubrange(pending.startIndex...idx)
            let line = String(decoding: lineData, as: UTF8.self)
            if !line.isEmpty { record(line) }
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty {
            record(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
    }

    private func record(_ line: String) {
        lastLines.append(line)
        if lastLines.count > 10 { lastLines.removeFirst() }
        emit(line)
    }
}
