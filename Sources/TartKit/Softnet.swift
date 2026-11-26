import Foundation

/// Readiness of the `softnet` helper that `tart run --net-softnet` needs.
public enum SoftnetStatus: Equatable, Sendable {
    /// softnet isn't on tart's PATH. Install with `brew install cirruslabs/cli/softnet`.
    case notInstalled
    /// softnet is installed but isn't setuid root and passwordless sudo isn't available.
    /// tart would try to fix this by prompting for a sudo password on a terminal, which
    /// a GUI-launched `tart run` doesn't have, so the launch fails. Holds the real
    /// (symlink-resolved) path of the binary.
    case needsSetup(path: String)
    case ready(path: String)
}

public enum SoftnetError: LocalizedError, Sendable {
    case notInstalled
    case setupFailed(String)
    case setupCancelled

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Softnet isn't installed. Install it with `brew install cirruslabs/cli/softnet`, then try again."
        case let .setupFailed(detail):
            return "Could not set up Softnet: \(detail)"
        case .setupCancelled:
            return "Softnet setup was cancelled. Softnet needs administrator rights once to run (it sets the setuid bit on the softnet binary)."
        }
    }
}

/// Checks and prepares the softnet helper, mirroring what tart itself checks before
/// `--net-softnet` (softnet on PATH, then setuid root or passwordless sudo).
public enum Softnet {

    /// Finds `softnet` the same way tart does: the first executable on PATH.
    public static func locate(searchPath: [String], fileManager: FileManager = .default) -> URL? {
        for dir in searchPath where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("softnet")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// True when the file (after resolving symlinks) is owned by root with the setuid bit.
    public static func isSetuidRoot(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let real = url.resolvingSymlinksInPath().path
        guard let attrs = try? fileManager.attributesOfItem(atPath: real),
              let owner = attrs[.ownerAccountID] as? NSNumber,
              let perms = attrs[.posixPermissions] as? NSNumber
        else { return false }
        return owner.intValue == 0 && (perms.intValue & Int(S_ISUID)) != 0
    }

    /// Determines whether `tart run --net-softnet` can start without an interactive prompt.
    /// `passwordlessSudo` is asked only when the setuid bit is missing.
    public static func status(
        searchPath: [String],
        fileManager: FileManager = .default,
        passwordlessSudo: (URL) async -> Bool = Softnet.canRunWithoutPassword
    ) async -> SoftnetStatus {
        guard let url = locate(searchPath: searchPath, fileManager: fileManager) else { return .notInstalled }
        let real = url.resolvingSymlinksInPath().path
        if isSetuidRoot(url, fileManager: fileManager) { return .ready(path: real) }
        if await passwordlessSudo(url) { return .ready(path: real) }
        return .needsSetup(path: real)
    }

    /// Same probe tart uses: `sudo --non-interactive softnet --help`.
    public static func canRunWithoutPassword(_ softnet: URL) async -> Bool {
        let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: ["--non-interactive", softnet.path, "--help"],
            stdin: ""
        )
        return result?.exitCode == 0
    }

    /// Shell command that makes softnet setuid root (what tart runs via sudo).
    public static func setupShellCommand(path: String) -> String {
        let quoted = shellQuote(path)
        return "/usr/sbin/chown root \(quoted) && /bin/chmod u+s \(quoted)"
    }

    /// AppleScript that runs `setupShellCommand` with the standard macOS admin password dialog.
    public static func setupAppleScript(path: String) -> String {
        let command = setupShellCommand(path: path)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(command)\" with administrator privileges"
    }

    /// Makes softnet setuid root, asking for an admin password with the system dialog.
    public static func setUp(path: String) async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", setupAppleScript(path: path)]
        )
        guard result.exitCode == 0 else {
            // -128 is AppleScript's "User canceled."
            if result.stderr.contains("-128") { throw SoftnetError.setupCancelled }
            throw SoftnetError.setupFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Host capabilities that decide whether any VM can run at all.
public enum HostSupport {
    /// `kern.hv_support`: 1 when Hypervisor.framework is usable. It is 0 when this
    /// Mac is itself a virtual machine, where tart cannot boot macOS (or, before
    /// M3 + macOS 15, any) guests.
    public static func hypervisorAvailable() -> Bool? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_support", &value, &size, nil, 0) == 0 else { return nil }
        return value != 0
    }

    /// True when running inside a virtual machine (`kern.hv_vmm_present`).
    public static func isVirtualMachine() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 else { return false }
        return value != 0
    }
}

/// Something that would make `tart run` fail before the VM boots.
public enum LaunchProblem: Equatable, Sendable, LocalizedError {
    case hypervisorUnavailable(isVirtualMachine: Bool)
    case softnetNotInstalled
    /// Softnet needs a one-time admin step; the app can do it with `Softnet.setUp(path:)`.
    case softnetNeedsSetup(path: String)

    public var errorDescription: String? {
        switch self {
        case let .hypervisorUnavailable(isVM):
            return isVM
                ? "This Mac is itself a virtual machine, so it can't run tart VMs (virtualization isn't available inside a VM). Run TartUI on a physical Apple Silicon Mac."
                : "Virtualization isn't available on this Mac (kern.hv_support is 0), so tart can't start VMs."
        case .softnetNotInstalled:
            return SoftnetError.notInstalled.errorDescription
        case let .softnetNeedsSetup(path):
            return "Softnet needs administrator rights once to run (setuid on \(path))."
        }
    }
}

public enum LaunchPreflight {
    /// Checks the host and the chosen options before running `tart run`.
    public static func check(
        options: RunOptions,
        hypervisorAvailable: Bool?,
        isVirtualMachine: Bool,
        softnetStatus: () async -> SoftnetStatus
    ) async -> LaunchProblem? {
        if hypervisorAvailable == false {
            return .hypervisorUnavailable(isVirtualMachine: isVirtualMachine)
        }
        guard options.softnet else { return nil }
        switch await softnetStatus() {
        case .notInstalled: return .softnetNotInstalled
        case let .needsSetup(path): return .softnetNeedsSetup(path: path)
        case .ready: return nil
        }
    }
}
