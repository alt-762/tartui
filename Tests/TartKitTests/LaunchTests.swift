import XCTest
@testable import TartKit

/// Tests for how `tart run` is built and spawned. A fake `tart` shell script stands
/// in for the real CLI so the launch path is exercised end to end without a VM.
final class LaunchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tartui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes an executable shell script into the temp dir.
    @discardableResult
    private func script(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 5) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? String(contentsOf: url, encoding: .utf8), s.hasSuffix("END\n") { return s }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    // MARK: - Argument building

    func testMacOSDefaultRunArguments() {
        let cli = TartCLI(binary: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertEqual(cli.runArguments(name: "sequoia", options: RunOptions()), ["run", "sequoia", "--suspendable"])
    }

    func testRecoveryAndBridged() {
        let cli = TartCLI(binary: URL(fileURLWithPath: "/usr/bin/true"))
        var opts = RunOptions()
        opts.recovery = true
        opts.bridgedInterface = "en0"
        XCTAssertEqual(cli.runArguments(name: "vm", options: opts),
                       ["run", "vm", "--suspendable", "--recovery", "--net-bridged", "en0"])
    }

    func testSoftnetWithoutExtras() {
        let cli = TartCLI(binary: URL(fileURLWithPath: "/usr/bin/true"))
        var opts = RunOptions()
        opts.softnet = true
        XCTAssertEqual(cli.runArguments(name: "vm", options: opts), ["run", "vm", "--suspendable", "--net-softnet"])
    }

    // MARK: - Environment

    func testLaunchEnvironmentAddsHomebrewToMinimalGUIPath() {
        let env = TartCLI.launchEnvironment(
            binary: URL(fileURLWithPath: "/opt/homebrew/bin/tart"),
            base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me"]
        )
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["HOME"], "/Users/me")
    }

    func testLaunchEnvironmentWithoutPath() {
        let env = TartCLI.launchEnvironment(binary: URL(fileURLWithPath: "/custom/tart"), base: [:])
        XCTAssertEqual(env["PATH"], "/custom:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    // MARK: - Process launch

    /// `tart run` must be spawned with the built arguments and keep running detached.
    func testStartLaunchesDetachedWithArgumentsAndPath() throws {
        let record = dir.appendingPathComponent("record.txt")
        let fakeTart = try script("tart", """
        {
          for a in "$@"; do echo "ARG:$a"; done
          echo "PATH:$PATH"
          echo "SOFTNET:$(command -v softnet)"
          echo END
        } > '\(record.path)'
        exec sleep 30
        """)
        // softnet sits next to tart (as with Homebrew); the app's PATH doesn't include it.
        try script("softnet", "exit 0")
        let cli = TartCLI(binary: fakeTart, baseEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])

        var opts = RunOptions()
        opts.softnet = true
        opts.softnetAllow = ["192.168.1.0/24"]
        opts.softnetExpose = ["2222:22"]

        let exited = expectation(description: "exit")
        let process = try cli.start(name: "mac", options: opts, logFile: dir.appendingPathComponent("run.log")) { _ in
            exited.fulfill()
        }

        let output = try XCTUnwrap(waitForFile(record), "fake tart never ran")
        let args = output.split(separator: "\n").filter { $0.hasPrefix("ARG:") }.map { String($0.dropFirst(4)) }
        XCTAssertEqual(args, cli.runArguments(name: "mac", options: opts))
        XCTAssertTrue(output.contains("PATH:\(dir.path):/opt/homebrew/bin"), output)
        XCTAssertTrue(output.contains("SOFTNET:\(dir.path)/softnet"), "softnet must be found on tart's PATH:\n\(output)")
        XCTAssertTrue(process.isRunning, "tart run must stay alive for the VM's lifetime")

        process.terminate()
        wait(for: [exited], timeout: 5)
    }

    /// A failing `tart run` reports its exit code and leaves its output in the log.
    func testFailedStartReportsExitCodeAndLog() throws {
        let fakeTart = try script("tart", """
        echo "Error: The virtual machine failed to start." >&2
        exit 3
        """)
        let log = dir.appendingPathComponent("run.log")
        let cli = TartCLI(binary: fakeTart)
        let exited = expectation(description: "exit")
        let code = LockedBox<Int32>()
        _ = try cli.start(name: "mac", options: RunOptions(), logFile: log) { status in
            code.value = status
            exited.fulfill()
        }
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(code.value, 3)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("failed to start"))
    }

    /// The child gets /dev/null as stdin, so a prompt (e.g. sudo) fails instead of hanging.
    func testStartDoesNotInheritStdin() throws {
        let fakeTart = try script("tart", "read line; echo \"read-exit:$?\"")
        let log = dir.appendingPathComponent("run.log")
        let exited = expectation(description: "exit")
        _ = try TartCLI(binary: fakeTart).start(name: "vm", options: RunOptions(), logFile: log) { _ in
            exited.fulfill()
        }
        wait(for: [exited], timeout: 5)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("read-exit:1"))
    }

    func testMissingBinaryThrowsLaunchFailed() {
        let cli = TartCLI(binary: dir.appendingPathComponent("does-not-exist"))
        XCTAssertThrowsError(try cli.start(name: "vm", options: RunOptions(), logFile: nil) { _ in }) { error in
            guard case ProcessError.launchFailed = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Softnet / preflight

    func testSoftnetStatus() async throws {
        let none = await Softnet.status(searchPath: [dir.path], passwordlessSudo: { _ in true })
        XCTAssertEqual(none, .notInstalled)

        let softnet = try script("softnet", "exit 0")
        let real = softnet.resolvingSymlinksInPath().path
        let needsSetup = await Softnet.status(searchPath: ["/nonexistent", dir.path], passwordlessSudo: { _ in false })
        XCTAssertEqual(needsSetup, .needsSetup(path: real))
        let viaSudo = await Softnet.status(searchPath: [dir.path], passwordlessSudo: { _ in true })
        XCTAssertEqual(viaSudo, .ready(path: real))
        XCTAssertFalse(Softnet.isSetuidRoot(softnet))
    }

    func testPreflight() async {
        var opts = RunOptions()
        let noHV = await LaunchPreflight.check(options: opts, hypervisorAvailable: false, isVirtualMachine: true) { .ready(path: "/x") }
        XCTAssertEqual(noHV, .hypervisorUnavailable(isVirtualMachine: true))

        let plain = await LaunchPreflight.check(options: opts, hypervisorAvailable: true, isVirtualMachine: false) {
            XCTFail("softnet must not be checked when it's off"); return .notInstalled
        }
        XCTAssertNil(plain)

        opts.softnet = true
        let missing = await LaunchPreflight.check(options: opts, hypervisorAvailable: true, isVirtualMachine: false) { .notInstalled }
        XCTAssertEqual(missing, .softnetNotInstalled)
        let setup = await LaunchPreflight.check(options: opts, hypervisorAvailable: nil, isVirtualMachine: false) { .needsSetup(path: "/s") }
        XCTAssertEqual(setup, .softnetNeedsSetup(path: "/s"))
        let ready = await LaunchPreflight.check(options: opts, hypervisorAvailable: true, isVirtualMachine: false) { .ready(path: "/s") }
        XCTAssertNil(ready)
    }

    func testSoftnetSetupScriptQuoting() {
        XCTAssertEqual(
            Softnet.setupShellCommand(path: "/opt/homebrew/Cellar/softnet/0.26.0/bin/softnet"),
            "/usr/sbin/chown root '/opt/homebrew/Cellar/softnet/0.26.0/bin/softnet' && /bin/chmod u+s '/opt/homebrew/Cellar/softnet/0.26.0/bin/softnet'"
        )
        XCTAssertEqual(
            Softnet.setupAppleScript(path: #"/a b/it's "x""#),
            #"do shell script "/usr/sbin/chown root '/a b/it'\\''s \"x\"' && /bin/chmod u+s '/a b/it'\\''s \"x\"'" with administrator privileges"#
        )
    }

    // MARK: - Persisted options

    func testRunOptionsPersistPerVM() throws {
        let suite = "tartui-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RunOptionsStore(defaults: defaults)

        XCTAssertEqual(store.options(for: "vm"), RunOptions())

        var opts = RunOptions()
        opts.softnet = true
        opts.softnetAllow = ["10.0.0.0/8"]
        opts.softnetExpose = ["2222:22"]
        opts.sharedDirectories = ["src:/Users/me/src"]
        store.save(opts, for: "vm")
        XCTAssertEqual(RunOptionsStore(defaults: defaults).options(for: "vm"), opts)
        XCTAssertEqual(store.options(for: "other"), RunOptions())

        store.rename("vm", to: "vm2")
        XCTAssertEqual(store.options(for: "vm"), RunOptions())
        XCTAssertEqual(store.options(for: "vm2"), opts)

        store.remove("vm2")
        XCTAssertEqual(store.options(for: "vm2"), RunOptions())
    }

    func testRunOptionsDecodeLeniently() throws {
        let opts = try JSONDecoder().decode(RunOptions.self, from: Data(#"{"softnet":true}"#.utf8))
        XCTAssertTrue(opts.softnet)
        XCTAssertEqual(opts.softnetAllow, [])
        XCTAssertFalse(opts.noGraphics)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
