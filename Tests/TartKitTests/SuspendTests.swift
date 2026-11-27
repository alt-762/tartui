import XCTest
@testable import TartKit

/// Suspend, resume and cold boot, end to end against a fake `tart` that mimics the
/// real one's behaviour (tart 2.x, Sources/tart/Commands/{Run,Suspend,Stop}.swift):
///
/// - `tart run` holds the VM's PID; on SIGUSR1 it saves `state.vzvmsave` and exits 0,
///   but only if it was started with `--suspendable`. Otherwise it prints
///   "Failed to suspend the VM: ..." and exits 1, which shuts the VM down.
/// - `tart run` on a VM with saved state restores it instead of booting.
/// - `tart suspend` just signals the run process and returns 0 straight away.
/// - `tart stop` on a suspended VM deletes the saved state.
/// - `tart get` reports running / suspended / stopped from the PID and state file.
final class SuspendTests: XCTestCase {
    private var dir: URL!
    private var cli: TartCLI!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tartui-suspend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tart = dir.appendingPathComponent("tart")
        try Self.fakeTart.write(to: tart, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tart.path)
        cli = TartCLI(binary: tart, baseEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "FAKE_TART_DIR": dir.path,
        ])
    }

    override func tearDownWithError() throws {
        // Don't leave a fake `tart run` behind if a test failed midway.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for file in files where file.hasSuffix(".pid") {
            let text = (try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)) ?? ""
            if let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    static let fakeTart = #"""
    #!/bin/sh
    D="${FAKE_TART_DIR:?FAKE_TART_DIR is not set}"
    cmd="$1"; name="${2:?missing VM name}"; shift 2
    PIDF="$D/$name.pid"
    STATEF="$D/$name.state"
    state() {
      if [ -f "$PIDF" ]; then echo running
      elif [ -f "$STATEF" ]; then echo suspended
      else echo stopped; fi
    }
    case "$cmd" in
      run)
        suspendable=0
        for a in "$@"; do [ "$a" = "--suspendable" ] && suspendable=1; done
        echo "ARGS: $*"
        if [ -f "$PIDF" ]; then echo "VM \"$name\" is already running!" >&2; exit 1; fi
        if [ -f "$STATEF" ]; then
          # Real tart forces --suspendable when resuming.
          suspendable=1
          echo "restoring VM state from a snapshot..."
          rm -f "$STATEF"
          echo "resuming VM..."
        else
          echo "booting fresh"
        fi
        echo $$ > "$PIDF"
        on_usr1() {
          if [ "$suspendable" = 1 ]; then
            echo "creating a snapshot..."
            echo snapshot > "$STATEF"
            rm -f "$PIDF"; exit 0
          else
            echo "Failed to suspend the VM: The virtual machine configuration does not support saving."
            rm -f "$PIDF"; exit 1
          fi
        }
        trap on_usr1 USR1
        trap 'rm -f "$PIDF"; exit 0' INT TERM
        if [ -f "$D/ignore-suspend" ]; then trap '' USR1; fi
        while :; do sleep 1 & wait $!; done
        ;;
      suspend)
        if [ ! -f "$PIDF" ]; then echo "VM \"$name\" is not running" >&2; exit 1; fi
        kill -USR1 "$(cat "$PIDF")"
        ;;
      stop)
        case "$(state)" in
          suspended) rm -f "$STATEF" ;;
          running) kill -INT "$(cat "$PIDF")"; while [ -f "$PIDF" ]; do sleep 0.1; done ;;
          *) echo "VM \"$name\" is not running" >&2; exit 1 ;;
        esac
        ;;
      get)
        echo "{\"CPU\":4,\"Memory\":8192,\"Disk\":50,\"Display\":\"1024x768\",\"OS\":\"darwin\",\"State\":\"$(state)\"}"
        ;;
      *) echo "unknown command $cmd" >&2; exit 2 ;;
    esac
    """#

    // MARK: - Helpers

    private struct Run {
        let process: Process
        let log: URL
        let exited: XCTestExpectation
        let code: Box
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int32?
        var value: Int32? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    /// Starts `tart run` detached, as the app does, and waits until the VM is running.
    private func launch(_ name: String, _ options: RunOptions) throws -> Run {
        let logURL = dir.appendingPathComponent("\(name)-\(UUID().uuidString).log")
        let exited = expectation(description: "tart run \(name) exits")
        let code = Box()
        let process = try cli.start(name: name, options: options, logFile: logURL) { status in
            code.value = status
            exited.fulfill()
        }
        let pidFile = dir.appendingPathComponent("\(name).pid")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "\(name) never started")
        return Run(process: process, log: logURL, exited: exited, code: code)
    }

    private func log(_ run: Run) -> String {
        (try? String(contentsOf: run.log, encoding: .utf8)) ?? ""
    }

    private func state(_ name: String) async throws -> String {
        try await cli.state(name)
    }

    private func suspend(_ name: String) async throws {
        try await cli.suspend(name, timeout: .seconds(5), pollInterval: .milliseconds(50))
    }

    // MARK: - Arguments and options

    func testRunIsSuspendableByDefault() {
        XCTAssertTrue(RunOptions().suspendable)
        XCTAssertEqual(cli.runArguments(name: "vm", options: RunOptions()), ["run", "vm", "--suspendable"])
        var opts = RunOptions()
        opts.suspendable = false
        XCTAssertEqual(cli.runArguments(name: "vm", options: opts), ["run", "vm"])
    }

    func testResumeKeepsDeviceOptionsButForcesSuspendableAndNoRecovery() {
        var opts = RunOptions()
        opts.suspendable = false
        opts.recovery = true
        opts.noGraphics = true
        opts.softnet = true
        opts.softnetExpose = ["2222:22"]
        opts.sharedDirectories = ["src:/Users/me/src"]

        let resume = opts.forResume
        XCTAssertTrue(resume.suspendable)
        XCTAssertFalse(resume.recovery)
        XCTAssertTrue(resume.noGraphics)
        XCTAssertTrue(resume.softnet)
        XCTAssertEqual(resume.softnetExpose, ["2222:22"])
        XCTAssertEqual(resume.sharedDirectories, ["src:/Users/me/src"])
        XCTAssertEqual(cli.runArguments(name: "vm", options: resume),
                       ["run", "vm", "--suspendable", "--no-graphics", "--dir", "src:/Users/me/src",
                        "--net-softnet", "--net-softnet-expose", "2222:22"])
    }

    func testSuspendableOptionPersists() throws {
        // Options saved by builds before this setting existed turn it on.
        let old = try JSONDecoder().decode(RunOptions.self, from: Data(#"{"softnet":true}"#.utf8))
        XCTAssertTrue(old.suspendable)

        var opts = RunOptions()
        opts.suspendable = false
        let decoded = try JSONDecoder().decode(RunOptions.self, from: JSONEncoder().encode(opts))
        XCTAssertFalse(decoded.suspendable)
        XCTAssertEqual(decoded, opts)
    }

    // MARK: - Suspend and resume

    func testSuspendThenResumeRestoresState() async throws {
        let first = try launch("mac", RunOptions())
        let initialState = try await state("mac")
        XCTAssertEqual(initialState, "running")

        try await suspend("mac")
        await fulfillment(of: [first.exited], timeout: 5)
        XCTAssertEqual(first.code.value, 0, "a successful suspend ends tart run cleanly")
        let suspendedState = try await state("mac")
        XCTAssertEqual(suspendedState, "suspended")
        XCTAssertTrue(log(first).contains("creating a snapshot"), log(first))

        // Even if the saved options no longer have suspend on, resume must pass it.
        var saved = RunOptions()
        saved.suspendable = false
        let second = try launch("mac", saved.forResume)
        XCTAssertTrue(log(second).contains("ARGS: --suspendable"), log(second))
        XCTAssertTrue(log(second).contains("restoring VM state"), log(second))
        let resumedState = try await state("mac")
        XCTAssertEqual(resumedState, "running")

        // And it can be suspended again.
        try await suspend("mac")
        await fulfillment(of: [second.exited], timeout: 5)
        let againState = try await state("mac")
        XCTAssertEqual(againState, "suspended")
    }

    /// The reported bug: without `--suspendable`, tart can't save the VM and shuts it
    /// down, while `tart suspend` itself still exits 0. That must surface as a failure.
    func testSuspendWithoutSuspendableReportsShutdown() async throws {
        var opts = RunOptions()
        opts.suspendable = false
        let run = try launch("mac", opts)

        do {
            try await suspend("mac")
            XCTFail("suspend must fail when tart shuts the VM down")
        } catch let error as SuspendError {
            XCTAssertEqual(error, .vmStoppedInstead("mac"))
        }
        await fulfillment(of: [run.exited], timeout: 5)
        XCTAssertEqual(run.code.value, 1)
        let stoppedState = try await state("mac")
        XCTAssertEqual(stoppedState, "stopped")
        XCTAssertEqual(LaunchHints.suspendFailure(inLog: run.log),
                       "Failed to suspend the VM: The virtual machine configuration does not support saving.")
    }

    func testSuspendTimesOutWhileStillRunning() async throws {
        try "".write(to: dir.appendingPathComponent("ignore-suspend"), atomically: true, encoding: .utf8)
        let run = try launch("mac", RunOptions())
        do {
            try await cli.suspend("mac", timeout: .milliseconds(300), pollInterval: .milliseconds(50))
            XCTFail("expected a timeout")
        } catch let error as SuspendError {
            XCTAssertEqual(error, .timedOut("mac"))
        }
        run.process.terminate()
        await fulfillment(of: [run.exited], timeout: 5)
    }

    func testSuspendingAStoppedVMFails() async throws {
        do {
            try await suspend("mac")
            XCTFail("expected tart suspend to fail")
        } catch let ProcessError.nonZeroExit(command, _, stderr) {
            XCTAssertEqual(command, "tart suspend mac")
            XCTAssertTrue(stderr.contains("not running"), stderr)
        }
    }

    // MARK: - Cold boot

    func testColdBootDiscardsStateAndBootsFresh() async throws {
        let first = try launch("mac", RunOptions())
        try await suspend("mac")
        await fulfillment(of: [first.exited], timeout: 5)
        let suspendedState = try await state("mac")
        XCTAssertEqual(suspendedState, "suspended")

        try await cli.discardSuspendedState("mac")
        let stoppedState = try await state("mac")
        XCTAssertEqual(stoppedState, "stopped")

        // A cold boot may use different options, e.g. recovery.
        var opts = RunOptions()
        opts.recovery = true
        let second = try launch("mac", opts)
        XCTAssertTrue(log(second).contains("booting fresh"), log(second))
        XCTAssertFalse(log(second).contains("restoring"), log(second))
        XCTAssertTrue(log(second).contains("--recovery"), log(second))

        try await cli.stop("mac")
        await fulfillment(of: [second.exited], timeout: 5)
        let finalState = try await state("mac")
        XCTAssertEqual(finalState, "stopped")
    }

    // MARK: - Hints

    func testLaunchHints() {
        XCTAssertNotNil(LaunchHints.hint(forLog: "Error: Linux VMs without a machine identifier cannot be suspended or resumed"))
        XCTAssertNotNil(LaunchHints.hint(forLog: "Error: Unknown option '--suspendable'"))
        XCTAssertNil(LaunchHints.hint(forLog: "Error: The virtual machine failed to start."))
        XCTAssertNil(LaunchHints.suspendFailure(inLog: "creating a snapshot..."))
    }
}
