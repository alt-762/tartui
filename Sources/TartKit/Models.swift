import Foundation

/// Guest operating system family, used to pick an icon.
public enum GuestOS: Hashable, Sendable {
    case macOS
    case linux
    case unknown

    /// Maps tart's `OS` value ("darwin", "linux") to a family.
    public init(tartValue: String?) {
        switch tartValue?.lowercased() {
        case "darwin", "macos": self = .macOS
        case "linux": self = .linux
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .unknown: "Unknown OS"
        }
    }
}

/// One row of `tart list --format json`.
///
/// Tart's JSON keys are capitalised (`Name`, `Source`, `State`, ...). Decoding is
/// lenient so older/newer tart versions with extra or missing keys still work.
public struct TartVM: Identifiable, Hashable, Sendable, Decodable {
    public enum Source: String, Sendable, Decodable {
        case local
        case oci
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
            self = Source(rawValue: raw) ?? .unknown
        }
    }

    public var id: String { "\(source.rawValue):\(name)" }

    public let name: String
    public let source: Source
    /// Allocated disk size in GB.
    public let diskGB: Int?
    /// Actual size on disk in GB.
    public let sizeGB: Int?
    public let state: String
    public let accessed: String?
    /// Raw `OS` value ("darwin" / "linux"), if this tart version reports it in `tart list`.
    public let os: String?

    public var guestOS: GuestOS { GuestOS(tartValue: os) }

    public var isRunning: Bool { state.lowercased() == "running" }
    public var isSuspended: Bool { state.lowercased() == "suspended" }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case source = "Source"
        case disk = "Disk"
        case size = "Size"
        case sizeOnDisk = "SizeOnDisk"
        case state = "State"
        case running = "Running"
        case accessed = "Accessed"
        case os = "OS"
    }

    public init(name: String, source: Source, diskGB: Int?, sizeGB: Int?, state: String, accessed: String?, os: String? = nil) {
        self.name = name
        self.source = source
        self.diskGB = diskGB
        self.sizeGB = sizeGB
        self.state = state
        self.accessed = accessed
        self.os = os
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        source = (try? c.decode(Source.self, forKey: .source)) ?? .unknown
        diskGB = try? c.decode(Int.self, forKey: .disk)
        sizeGB = (try? c.decode(Int.self, forKey: .sizeOnDisk)) ?? (try? c.decode(Int.self, forKey: .size))
        if let state = try? c.decode(String.self, forKey: .state) {
            self.state = state
        } else if let running = try? c.decode(Bool.self, forKey: .running) {
            self.state = running ? "running" : "stopped"
        } else {
            self.state = "unknown"
        }
        accessed = try? c.decode(String.self, forKey: .accessed)
        os = try? c.decode(String.self, forKey: .os)
    }
}

/// Output of `tart get <name> --format json`.
public struct TartVMConfig: Hashable, Sendable, Decodable {
    public var cpu: Int
    /// Memory in MB.
    public var memoryMB: Int
    /// Disk size in GB.
    public var diskGB: Int
    /// e.g. "1024x768"
    public var display: String
    public var os: String
    public var state: String

    public var guestOS: GuestOS { GuestOS(tartValue: os) }

    enum CodingKeys: String, CodingKey {
        case cpu = "CPU"
        case memory = "Memory"
        case disk = "Disk"
        case display = "Display"
        case os = "OS"
        case state = "State"
        case running = "Running"
    }

    public init(cpu: Int, memoryMB: Int, diskGB: Int, display: String, os: String, state: String) {
        self.cpu = cpu
        self.memoryMB = memoryMB
        self.diskGB = diskGB
        self.display = display
        self.os = os
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = (try? c.decode(Int.self, forKey: .cpu)) ?? 0
        memoryMB = (try? c.decode(Int.self, forKey: .memory)) ?? 0
        diskGB = (try? c.decode(Int.self, forKey: .disk)) ?? 0
        display = (try? c.decode(String.self, forKey: .display)) ?? ""
        os = (try? c.decode(String.self, forKey: .os)) ?? "unknown"
        if let state = try? c.decode(String.self, forKey: .state) {
            self.state = state
        } else if let running = try? c.decode(Bool.self, forKey: .running) {
            self.state = running ? "running" : "stopped"
        } else {
            self.state = "unknown"
        }
    }
}

/// How a new VM should be created.
public enum CreateSource: Hashable, Sendable {
    /// `tart create --from-ipsw <path|latest>`
    case macOSIPSW(String)
    /// `tart create --linux`
    case linux
}

/// Options for `tart run`.
public struct RunOptions: Hashable, Sendable, Codable {
    public var noGraphics = false
    public var recovery = false
    /// Host directories to share, in tart's `name:path[:ro]` format.
    public var sharedDirectories: [String] = []
    /// Bridged interface name, nil for the default shared (NAT) network.
    /// Ignored when `softnet` is on, since tart accepts only one network mode.
    public var bridgedInterface: String?
    /// Run behind Softnet (`--net-softnet`), which isolates the VM from the
    /// host's LAN and from other VMs.
    public var softnet = false
    /// CIDRs the VM may still reach under Softnet (`--net-softnet-allow`).
    public var softnetAllow: [String] = []
    /// Port forwards from host to VM under Softnet, as `host:guest`
    /// (`--net-softnet-expose`).
    public var softnetExpose: [String] = []

    public init() {}

    // Lenient decoding so options saved by an older build (or with fields added
    // later) still load instead of silently resetting to defaults.
    enum CodingKeys: String, CodingKey {
        case noGraphics, recovery, sharedDirectories, bridgedInterface, softnet, softnetAllow, softnetExpose
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        noGraphics = (try? c.decode(Bool.self, forKey: .noGraphics)) ?? false
        recovery = (try? c.decode(Bool.self, forKey: .recovery)) ?? false
        sharedDirectories = (try? c.decode([String].self, forKey: .sharedDirectories)) ?? []
        bridgedInterface = try? c.decode(String.self, forKey: .bridgedInterface)
        softnet = (try? c.decode(Bool.self, forKey: .softnet)) ?? false
        softnetAllow = (try? c.decode([String].self, forKey: .softnetAllow)) ?? []
        softnetExpose = (try? c.decode([String].self, forKey: .softnetExpose)) ?? []
    }
}

/// Remembers the run options chosen for each VM, so Softnet, shared folders etc.
/// stick across launches and app restarts. Backed by UserDefaults.
public struct RunOptionsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    static let keyPrefix = "runOptions."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ vm: String) -> String { Self.keyPrefix + vm }

    /// Saved options for a VM, or defaults if none were saved.
    public func options(for vm: String) -> RunOptions {
        guard let data = defaults.data(forKey: key(vm)),
              let options = try? JSONDecoder().decode(RunOptions.self, from: data)
        else { return RunOptions() }
        return options
    }

    public func save(_ options: RunOptions, for vm: String) {
        if options == RunOptions() {
            defaults.removeObject(forKey: key(vm))
        } else if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: key(vm))
        }
    }

    public func remove(_ vm: String) {
        defaults.removeObject(forKey: key(vm))
    }

    /// Carries saved options over when a VM is renamed.
    public func rename(_ vm: String, to newName: String) {
        guard let data = defaults.data(forKey: key(vm)) else { return }
        defaults.set(data, forKey: key(newName))
        defaults.removeObject(forKey: key(vm))
    }
}
