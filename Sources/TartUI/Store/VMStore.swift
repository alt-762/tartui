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

/// App-wide state. Owns the TartCLI and is the single place views go through.
@MainActor
@Observable
final class VMStore {
    private(set) var vms: [TartVM] = []
    private(set) var configs: [String: TartVMConfig] = [:]
    private(set) var operations: [TartOperation] = []
    private(set) var tartVersion: String?
    var lastError: String?
    var isRefreshing = false

    /// `tart run` processes started by this app, keyed by VM name.
    private var runProcesses: [String: Process] = [:]
    private var pollTask: Task<Void, Never>?

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
        defer { isRefreshing = false }
        do {
            vms = try await cli.list()
        } catch {
            if !silently { lastError = error.localizedDescription }
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

    func start(_ name: String, options: RunOptions = RunOptions()) {
        perform {
            let cli = try self.requireCLI()
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("tartui-\(name).log")
            let process = try cli.start(name: name, options: options, logFile: log) { [weak store = self] code in
                Task { @MainActor in
                    store?.runProcesses[name] = nil
                    if code != 0 {
                        let tail = (try? String(contentsOf: log, encoding: .utf8))?
                            .split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
                        store?.lastError = "\(name) exited with code \(code). \(tail)"
                    }
                    await store?.refresh(silently: true)
                }
            }
            self.runProcesses[name] = process
            try? await Task.sleep(for: .seconds(1))
            await self.refresh(silently: true)
        }
    }

    func stop(_ name: String) {
        perform {
            try await self.requireCLI().stop(name)
            await self.refresh()
        }
    }

    func suspend(_ name: String) {
        perform {
            try await self.requireCLI().suspend(name)
            await self.refresh()
        }
    }

    func delete(_ name: String) {
        perform {
            try await self.requireCLI().delete(name)
            self.configs[name] = nil
            await self.refresh()
        }
    }

    func rename(_ name: String, to newName: String) {
        perform {
            try await self.requireCLI().rename(name, to: newName)
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
