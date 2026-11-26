import Foundation

public enum TartCLIError: LocalizedError, Sendable {
    case binaryNotFound
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "The tart CLI was not found. Install it with `brew install cirruslabs/cli/tart`, or set its path in Settings."
        case let .decodingFailed(detail):
            return "Could not read tart output: \(detail)"
        }
    }
}

/// Typed wrapper over the `tart` command line tool.
///
/// Every GUI action maps to exactly one tart subcommand, so the app never
/// touches `~/.tart` directly and stays compatible with tart upgrades.
public struct TartCLI: Sendable {
    public let binary: URL
    /// Environment every tart invocation runs with. See `launchEnvironment`.
    public let environment: [String: String]

    public init(binary: URL, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.binary = binary
        self.environment = Self.launchEnvironment(binary: binary, base: baseEnvironment)
    }

    /// Directories prepended to PATH for tart's child processes.
    static let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Builds the environment tart is launched with.
    ///
    /// Apps started from Finder/Dock get a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`).
    /// tart looks up helpers such as `softnet` (for `--net-softnet`) via PATH, so without
    /// this a Homebrew install of softnet is never found and `tart run --net-softnet` fails.
    public static func launchEnvironment(binary: URL, base: [String: String]) -> [String: String] {
        var env = base
        let existing = (base["PATH"]?.isEmpty == false ? base["PATH"]! : "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        let candidates = [binary.deletingLastPathComponent().path] + extraSearchPaths + existing
        var seen = Set<String>()
        env["PATH"] = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// PATH entries tart will search, in order.
    public var searchPath: [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    /// Finds tart in the usual install locations, or via an explicit override.
    public static func locate(override: String? = nil) throws -> TartCLI {
        var candidates: [String] = []
        if let override, !override.isEmpty { candidates.append(override) }
        candidates += [
            "/opt/homebrew/bin/tart",
            "/usr/local/bin/tart",
            "/Applications/tart.app/Contents/MacOS/tart",
        ]
        // GUI apps don't inherit the shell PATH, so also scan PATH if present.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/tart" }
        }
        let fm = FileManager.default
        guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw TartCLIError.binaryNotFound
        }
        return TartCLI(binary: URL(fileURLWithPath: found))
    }

    // MARK: - Low-level

    @discardableResult
    func run(_ args: [String]) async throws -> String {
        let result = try await ProcessRunner.run(binary, arguments: args, environment: environment)
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(
                command: (["tart"] + args).joined(separator: " "),
                code: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result.stdout
    }

    func stream(_ args: [String]) -> AsyncThrowingStream<String, Error> {
        ProcessRunner.stream(binary, arguments: args, environment: environment)
    }

    // MARK: - Queries

    public func version() async throws -> String {
        try await run(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `tart list --format json` — both local VMs and cached OCI images.
    public func list() async throws -> [TartVM] {
        let out = try await run(["list", "--format", "json"])
        do {
            return try JSONDecoder().decode([TartVM].self, from: Data(out.utf8))
        } catch {
            throw TartCLIError.decodingFailed(error.localizedDescription)
        }
    }

    /// `tart get <name> --format json`
    public func get(_ name: String) async throws -> TartVMConfig {
        let out = try await run(["get", name, "--format", "json"])
        do {
            return try JSONDecoder().decode(TartVMConfig.self, from: Data(out.utf8))
        } catch {
            throw TartCLIError.decodingFailed(error.localizedDescription)
        }
    }

    /// `tart ip <name>` — only works while the VM is running.
    public func ip(_ name: String, wait seconds: Int = 0) async throws -> String {
        var args = ["ip", name]
        if seconds > 0 { args += ["--wait", String(seconds)] }
        return try await run(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lifecycle

    /// `tart create`. Creating from an IPSW downloads and installs macOS, so this streams progress.
    public func create(name: String, source: CreateSource, diskSizeGB: Int?) -> AsyncThrowingStream<String, Error> {
        var args = ["create", name]
        switch source {
        case let .macOSIPSW(ipsw): args += ["--from-ipsw", ipsw]
        case .linux: args += ["--linux"]
        }
        if let diskSizeGB { args += ["--disk-size", String(diskSizeGB)] }
        return stream(args)
    }

    /// `tart clone <source> <new>` — source may be a local VM or a remote OCI reference.
    /// Cloning a remote image pulls it first, so this streams progress.
    public func clone(source: String, newName: String) -> AsyncThrowingStream<String, Error> {
        stream(["clone", source, newName])
    }

    /// Builds the argument list for `tart run`. The process stays alive for the
    /// lifetime of the VM, so callers launch it detached.
    public func runArguments(name: String, options: RunOptions) -> [String] {
        var args = ["run", name]
        if options.noGraphics { args.append("--no-graphics") }
        if options.recovery { args.append("--recovery") }
        for dir in options.sharedDirectories { args += ["--dir", dir] }
        if options.softnet {
            args.append("--net-softnet")
            if !options.softnetAllow.isEmpty {
                args += ["--net-softnet-allow", options.softnetAllow.joined(separator: ",")]
            }
            if !options.softnetExpose.isEmpty {
                args += ["--net-softnet-expose", options.softnetExpose.joined(separator: ",")]
            }
        } else if let iface = options.bridgedInterface {
            args += ["--net-bridged", iface]
        }
        return args
    }

    public func start(
        name: String,
        options: RunOptions,
        logFile: URL?,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> Process {
        try ProcessRunner.launchDetached(
            binary,
            arguments: runArguments(name: name, options: options),
            environment: environment,
            logFile: logFile,
            onExit: onExit
        )
    }

    /// Host and Softnet checks to run before `start`, so failures are explained
    /// up front instead of surfacing as a cryptic exit code.
    public func preflight(_ options: RunOptions) async -> LaunchProblem? {
        let path = searchPath
        return await LaunchPreflight.check(
            options: options,
            hypervisorAvailable: HostSupport.hypervisorAvailable(),
            isVirtualMachine: HostSupport.isVirtualMachine(),
            softnetStatus: { await Softnet.status(searchPath: path) }
        )
    }

    public func stop(_ name: String, timeoutSeconds: Int? = nil) async throws {
        var args = ["stop", name]
        if let timeoutSeconds { args += ["--timeout", String(timeoutSeconds)] }
        try await run(args)
    }

    public func suspend(_ name: String) async throws {
        try await run(["suspend", name])
    }

    public func rename(_ name: String, to newName: String) async throws {
        try await run(["rename", name, newName])
    }

    public func delete(_ name: String) async throws {
        try await run(["delete", name])
    }

    // MARK: - Settings

    /// `tart set` — only applies to stopped VMs. Pass nil to leave a value unchanged.
    public func set(
        _ name: String,
        cpu: Int? = nil,
        memoryMB: Int? = nil,
        diskSizeGB: Int? = nil,
        display: String? = nil,
        randomizeMAC: Bool = false
    ) async throws {
        var args = ["set", name]
        if let cpu { args += ["--cpu", String(cpu)] }
        if let memoryMB { args += ["--memory", String(memoryMB)] }
        if let diskSizeGB { args += ["--disk-size", String(diskSizeGB)] }
        if let display, !display.isEmpty { args += ["--display", display] }
        if randomizeMAC { args.append("--random-mac") }
        guard args.count > 2 else { return }
        try await run(args)
    }

    // MARK: - Registry / images

    public func pull(_ remote: String) -> AsyncThrowingStream<String, Error> {
        stream(["pull", remote])
    }

    public func push(_ localName: String, to remotes: [String]) -> AsyncThrowingStream<String, Error> {
        stream(["push", localName] + remotes)
    }

    /// `tart login <host> --username <u> --password-stdin`
    public func login(host: String, username: String, password: String) async throws {
        let args = ["login", host, "--username", username, "--password-stdin"]
        let result = try await ProcessRunner.run(binary, arguments: args, environment: environment, stdin: password)
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(command: "tart login \(host)", code: result.exitCode, stderr: result.stderr)
        }
    }

    /// `tart prune` — clears cached OCI images / IPSWs.
    public func prune(entries: String = "caches") async throws {
        try await run(["prune", "--entries", entries])
    }
}
