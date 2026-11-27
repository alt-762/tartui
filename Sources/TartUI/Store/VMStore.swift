import Foundation
import Observation
import TartKit

/// A long-running tart operation (create, clone, pull, push) shown in the Activity panel.
@Observable
final class TartOperation: Identifiable {
    enum Status { case running, succeeded, failed(String), cancelled }

    let id = UUID()
    let title: String
    var lines: [String] = []
    var status: Status = .running
    var task: Task<Void, Never>?

    init(title: String) { self.title = title }

    var lastLine: String { lines.last ?? "" }
    var isRunning: Bool { if case .running = status { return true } else { return false } }
}

/// A start that is waiting for the user to approve Softnet's one-time admin setup.
struct PendingSoftnetSetup: Identifiable, Equatable {
    let vm: String
    let options: RunOptions
    let softnetPath: String
    /// Discard the VM's suspended state before launching (cold boot).
    var coldBoot = false
    var id: String { vm }
}

/// An error whose text is already written for the user.
struct StoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// App-wide state. Owns the TartCLI and is the single place views go through.
@MainActor
@Observable
final class VMStore {
    private(set) var vms: [TartVM] = []
    private(set) var configs: [String: TartVMConfig] = [:]
    private(set) var operations: [TartOperation] = []
    private(set) var tartVersion: String?
    var lastError: String?
    /// True while a user-visible refresh (first load, toolbar/⌘R, after an action) is running.
    /// Background polls never set it, so the UI doesn't flicker every few seconds.
    private(set) var isRefreshing = false
    /// False until the first `tart list` has finished (successfully or not).
    private(set) var hasLoaded = false
    /// VMs whose `tart run` is being prepared or launched, so Start can't be double-clicked.
    private(set) var startingVMs: Set<String> = []
    /// VMs whose state is being saved by `tart suspend`.
    private(set) var suspendingVMs: Set<String> = []
    /// Set when a Softnet start needs the user to approve the admin prompt.
    var pendingSoftnetSetup: PendingSoftnetSetup?
    private let runOptionsStore = RunOptionsStore()

    /// `tart run` processes started by this app, keyed by VM name.
    private var runProcesses: [String: Process] = [:]
    /// Options each app-started VM is running with, so the UI knows whether it can suspend.
    private var launchedOptions: [String: RunOptions] = [:]
    private var pollTask: Task<Void, Never>?
    /// VM names we've already run `tart get` on to learn their OS, so polling doesn't repeat it.
    private var osLookupsAttempted: Set<String> = []

    private var cli: TartCLI?

    var localVMs: [TartVM] { vms.filter { $0.source == .local }.sorted { $0.name < $1.name } }
    var ociImages: [TartVM] { vms.filter { $0.source == .oci }.sorted { $0.name < $1.name } }

    init() {
        reloadCLI()
    }

    // MARK: - Setup

    func reloadCLI() {
        let override = UserDefaults.standard.string(forKey: "tartPath")
        do {
            cli = try TartCLI.locate(override: override)
            lastError = nil
            Task {
                tartVersion = try? await cli?.version()
                await refresh()
            }
        } catch {
            cli = nil
            lastError = error.localizedDescription
        }
    }

    /// Polls `tart list` so state changes made outside the app (CLI, CI) show up.
    func startPolling(every seconds: Double = 5) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                await self?.refresh(silently: true)
            }
        }
    }

    private func requireCLI() throws -> TartCLI {
        guard let cli else { throw TartCLIError.binaryNotFound }
        return cli
    }

    // MARK: - Queries

    func refresh(silently: Bool = false) async {
        guard let cli else { return }
        if !silently { isRefreshing = true }
        defer {
            if !silently { isRefreshing = false }
            hasLoaded = true
        }
        do {
            vms = try await cli.list()
        } catch {
            if !silently { lastError = error.localizedDescription }
            return
        }
        await lookUpMissingOS(using: cli)
    }

    /// The guest OS of a VM or image, from `tart list` when it reports it,
    /// otherwise from the `tart get` config we fetched for it.
    func guestOS(for vm: TartVM) -> GuestOS {
        if vm.guestOS != .unknown { return vm.guestOS }
        return configs[vm.name]?.guestOS ?? .unknown
    }

    /// Older tart versions don't include `OS` in `tart list`, so fall back to one
    /// `tart get` per VM. Runs once per name; failures are ignored (icon stays generic).
    private func lookUpMissingOS(using cli: TartCLI) async {
        let missing = vms.filter {
            $0.os == nil && configs[$0.name] == nil && !osLookupsAttempted.contains($0.name)
        }
        for vm in missing {
            osLookupsAttempted.insert(vm.name)
            if let config = try? await cli.get(vm.name) {
                configs[vm.name] = config
            }
        }
    }

    func loadConfig(for name: String) async {
        do {
            configs[name] = try await requireCLI().get(name)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func ip(for name: String) async -> String? {
        try? await cli?.ip(name)
    }

    // MARK: - Lifecycle

    /// Saved run options for a VM (Softnet, shared folder, headless...).
    func runOptions(for name: String) -> RunOptions {
        runOptionsStore.options(for: name)
    }

    func saveRunOptions(_ options: RunOptions, for name: String) {
        runOptionsStore.save(options, for: name)
    }

    /// Starts a VM with the given options, or with its saved options when nil.
    /// Runs host/Softnet checks first; if Softnet needs its one-time admin setup,
    /// asks for confirmation via `pendingSoftnetSetup` and resumes after it.
    ///
    /// A suspended VM is resumed instead (see `resume`), since its saved state only
    /// restores with the options it was started with.
    func start(_ name: String, options: RunOptions? = nil) {
        if vms.first(where: { $0.name == name && $0.source == .local })?.isSuspended == true {
            resume(name)
            return
        }
        let options = options ?? runOptionsStore.options(for: name)
        runOptionsStore.save(options, for: name)
        launchWithChecks(name, options: options)
    }

    /// Resumes a suspended VM from its saved state, using the options it was started with.
    func resume(_ name: String) {
        launchWithChecks(name, options: runOptionsStore.options(for: name).forResume)
    }

    /// Discards a suspended VM's saved state and boots it fresh with the given
    /// (or saved) options. Anything unsaved in the guest is lost.
    func coldBoot(_ name: String, options: RunOptions? = nil) {
        let options = options ?? runOptionsStore.options(for: name)
        runOptionsStore.save(options, for: name)
        launchWithChecks(name, options: options, coldBoot: true)
    }

    /// Whether the Suspend action should be offered for a running VM. A VM this app
    /// started without `--suspendable` would be shut down by tart, not suspended.
    /// VMs started elsewhere are allowed; `suspend` reports if tart stops them.
    func canSuspend(_ name: String) -> Bool {
        launchedOptions[name]?.suspendable ?? true
    }

    /// Runs the host/Softnet checks and launches. With `coldBoot`, the saved state is
    /// discarded only once the checks pass, so a failed or cancelled start keeps it.
    private func launchWithChecks(_ name: String, options: RunOptions, coldBoot: Bool = false) {
        guard !startingVMs.contains(name) else { return }
        startingVMs.insert(name)
        perform {
            defer { self.startingVMs.remove(name) }
            let cli = try self.requireCLI()
            switch await cli.preflight(options) {
            case .none:
                if coldBoot { try await self.discardStateIfSuspended(name, cli: cli) }
                try await self.launch(name, options: options, cli: cli)
            case let .some(.softnetNeedsSetup(path)):
                self.pendingSoftnetSetup = PendingSoftnetSetup(
                    vm: name, options: options, softnetPath: path, coldBoot: coldBoot)
            case let .some(problem):
                throw problem
            }
        }
    }

    /// Called when the user confirms the Softnet admin prompt.
    func completeSoftnetSetup(_ pending: PendingSoftnetSetup) {
        pendingSoftnetSetup = nil
        startingVMs.insert(pending.vm)
        perform {
            defer { self.startingVMs.remove(pending.vm) }
            try await Softnet.setUp(path: pending.softnetPath)
            let cli = try self.requireCLI()
            if let problem = await cli.preflight(pending.options) { throw problem }
            if pending.coldBoot { try await self.discardStateIfSuspended(pending.vm, cli: cli) }
            try await self.launch(pending.vm, options: pending.options, cli: cli)
        }
    }

    private func discardStateIfSuspended(_ name: String, cli: TartCLI) async throws {
        if try await cli.state(name) == "suspended" {
            try await cli.discardSuspendedState(name)
        }
    }

    private func launch(_ name: String, options: RunOptions, cli: TartCLI) async throws {
        let log = Self.logURL(for: name)
        let process = try cli.start(name: name, options: options, logFile: log) { [weak store = self] code in
            Task { @MainActor in
                guard let store else { return }
                store.runProcesses[name] = nil
                store.launchedOptions[name] = nil
                // A failed suspend is reported by `suspend` itself, with the same log.
                let failedSuspend = store.suspendingVMs.contains(name)
                    || LaunchHints.suspendFailure(inLog: log) != nil
                if code != 0 && !failedSuspend {
                    store.lastError = Self.exitMessage(name: name, code: code, log: log)
                }
                await store.refresh(silently: true)
            }
        }
        runProcesses[name] = process
        launchedOptions[name] = options
        try? await Task.sleep(for: .seconds(1))
        await refresh(silently: true)
    }

    /// Error text for a `tart run` that exited with a non-zero code: the last lines
    /// of its log plus a hint for known causes.
    static func exitMessage(name: String, code: Int32, log: URL) -> String {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let tail = text.split(separator: "\n").suffix(8).joined(separator: "\n")
        var message = "\(name) exited with code \(code).\n\(tail)"
        if let hint = LaunchHints.hint(forLog: text) { message += "\n\n\(hint)" }
        return message + "\n\nFull log: \(log.path)"
    }

    /// Per-VM `tart run` output, kept in ~/Library/Logs/TartUI so it survives a failed launch.
    static func logURL(for name: String) -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/TartUI", isDirectory: true)
            ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).log")
    }

    func stop(_ name: String) {
        perform {
            try await self.requireCLI().stop(name)
            await self.refresh()
        }
    }

    /// Suspends a running VM and waits until tart has saved its state.
    func suspend(_ name: String) {
        guard !suspendingVMs.contains(name) else { return }
        suspendingVMs.insert(name)
        perform {
            defer { self.suspendingVMs.remove(name) }
            do {
                try await self.requireCLI().suspend(name)
            } catch let error as SuspendError {
                await self.refresh()
                var message = error.localizedDescription
                if case .vmStoppedInstead = error,
                   let detail = LaunchHints.suspendFailure(inLog: Self.logURL(for: name)) {
                    message += "\n\ntart said: \(detail)"
                }
                throw StoreError(message: message)
            }
            await self.refresh()
        }
    }

    func delete(_ name: String) {
        perform {
            try await self.requireCLI().delete(name)
            self.configs[name] = nil
            self.runOptionsStore.remove(name)
            await self.refresh()
        }
    }

    func rename(_ name: String, to newName: String) {
        perform {
            try await self.requireCLI().rename(name, to: newName)
            self.runOptionsStore.rename(name, to: newName)
            await self.refresh()
        }
    }

    func applySettings(_ name: String, cpu: Int?, memoryMB: Int?, diskSizeGB: Int?, display: String?) {
        perform {
            try await self.requireCLI().set(name, cpu: cpu, memoryMB: memoryMB, diskSizeGB: diskSizeGB, display: display)
            await self.loadConfig(for: name)
            await self.refresh()
        }
    }

    // MARK: - Long operations

    func create(name: String, source: CreateSource, diskSizeGB: Int?) {
        track("Create \(name)") { cli in cli.create(name: name, source: source, diskSizeGB: diskSizeGB) }
    }

    func clone(source: String, newName: String) {
        track("Clone \(source) → \(newName)") { cli in cli.clone(source: source, newName: newName) }
    }

    func pull(_ remote: String) {
        track("Pull \(remote)") { cli in cli.pull(remote) }
    }

    func push(_ local: String, to remote: String) {
        track("Push \(local) → \(remote)") { cli in cli.push(local, to: [remote]) }
    }

    func login(host: String, username: String, password: String) async -> Bool {
        do {
            try await requireCLI().login(host: host, username: username, password: password)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func prune() {
        perform {
            try await self.requireCLI().prune()
            await self.refresh()
        }
    }

    func cancel(_ op: TartOperation) {
        op.task?.cancel()
        op.status = .cancelled
    }

    func clearFinishedOperations() {
        operations.removeAll { !$0.isRunning }
    }

    // MARK: - Plumbing

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { lastError = error.localizedDescription }
        }
    }

    private func track(_ title: String, _ makeStream: @escaping (TartCLI) -> AsyncThrowingStream<String, Error>) {
        let op = TartOperation(title: title)
        operations.insert(op, at: 0)
        op.task = Task {
            do {
                let cli = try requireCLI()
                for try await line in makeStream(cli) {
                    op.lines.append(line)
                    if op.lines.count > 500 { op.lines.removeFirst(op.lines.count - 500) }
                }
                op.status = Task.isCancelled ? .cancelled : .succeeded
            } catch is CancellationError {
                op.status = .cancelled
            } catch {
                op.status = .failed(error.localizedDescription)
            }
            await refresh(silently: true)
        }
    }
}
