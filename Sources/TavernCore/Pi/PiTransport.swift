import Foundation

/// Carries Pi RPC lines. The local transport runs `pi --mode rpc` as a child process; a later
/// Remote transports (SSH, TCP) implement the same protocol.
public protocol PiTransport: AnyObject, Sendable {
    /// Starts delivering complete stdout lines. `onClose` fires once when the stream ends.
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws
    /// Writes one record; the transport adds the LF.
    func send(_ line: Data) throws
    func close()
}

public enum PiTransportError: Error, Equatable {
    case notRunning
    case exited(status: Int32)
}

/// Runs a local Pi in RPC mode. Pi reads commands on stdin, writes records on stdout and
/// diagnostics on stderr (which Tavern never parses).
public final class PiProcessTransport: PiTransport, @unchecked Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL?

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var framer = LineFramer()

    /// A local `pi` launch in RPC mode, with `--continue` added unless it already picks a session,
    /// so a relaunch resumes the agent's latest session and its one Tavern thread (plan 2a).
    public static func continuing(_ argv: [String]) -> [String] {
        let words = argv.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard words.contains("pi"), words.contains("rpc") else { return argv }
        let sessionFlags: Set<String> = ["--continue", "-c", "--resume", "-r", "--session", "--session-id", "--fork", "--no-session"]
        if words.contains(where: sessionFlags.contains) { return argv }
        return argv + ["--continue"]
    }

    /// `executable` is an absolute path (for example from `which pi`); `arguments` default to RPC mode.
    public init(executable: URL, arguments: [String] = ["--mode", "rpc"], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    public func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            let lines = self.framer.push(chunk)
            self.lock.unlock()
            lines.forEach(onLine)
        }
        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            onClose(status == 0 ? nil : PiTransportError.exited(status: status))
        }

        try process.run()
        lock.lock()
        self.process = process
        self.stdin = input.fileHandleForWriting
        lock.unlock()
    }

    public func send(_ line: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let stdin, process?.isRunning == true else { throw PiTransportError.notRunning }
        try stdin.write(contentsOf: line + Data([0x0A]))
    }

    /// Closing stdin is Pi's documented shutdown: it disposes the runtime and exits.
    public func close() {
        lock.lock()
        let handle = stdin
        stdin = nil
        lock.unlock()
        try? handle?.close()
    }
}
