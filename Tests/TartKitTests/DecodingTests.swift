import XCTest
@testable import TartKit

final class DecodingTests: XCTestCase {
    func testDecodesTartList() throws {
        let json = """
        [
          {"Source":"local","Name":"sequoia","Disk":50,"Size":22,"SizeOnDisk":22,"State":"running","Accessed":"2026-11-25T10:00:00Z","Running":true},
          {"Source":"OCI","Name":"ghcr.io/cirruslabs/macos-sequoia-base:latest","Disk":50,"Size":25,"State":"stopped","Running":false}
        ]
        """
        let vms = try JSONDecoder().decode([TartVM].self, from: Data(json.utf8))
        XCTAssertEqual(vms.count, 2)
        XCTAssertEqual(vms[0].source, .local)
        XCTAssertTrue(vms[0].isRunning)
        XCTAssertEqual(vms[1].source, .oci)
        XCTAssertEqual(vms[1].sizeGB, 25)
    }

    func testFallsBackToRunningFlag() throws {
        let json = #"[{"Source":"local","Name":"old","Disk":40,"Size":10,"Running":true}]"#
        let vms = try JSONDecoder().decode([TartVM].self, from: Data(json.utf8))
        XCTAssertEqual(vms[0].state, "running")
    }

    func testDecodesOSFromTartList() throws {
        let json = """
        [
          {"Source":"local","Name":"mac","OS":"darwin","State":"stopped"},
          {"Source":"local","Name":"ubuntu","OS":"linux","State":"stopped"},
          {"Source":"local","Name":"old","State":"stopped"}
        ]
        """
        let vms = try JSONDecoder().decode([TartVM].self, from: Data(json.utf8))
        XCTAssertEqual(vms.map(\.guestOS), [.macOS, .linux, .unknown])
        XCTAssertNil(vms[2].os)
    }

    func testGuestOSFromConfig() throws {
        let json = #"{"CPU":2,"Memory":4096,"Disk":20,"Display":"1024x768","OS":"linux","State":"stopped"}"#
        let cfg = try JSONDecoder().decode(TartVMConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.guestOS, .linux)
    }

    func testDecodesTartGet() throws {
        let json = #"{"CPU":4,"Memory":8192,"Disk":50,"Display":"1024x768","OS":"darwin","State":"stopped"}"#
        let cfg = try JSONDecoder().decode(TartVMConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.cpu, 4)
        XCTAssertEqual(cfg.memoryMB, 8192)
        XCTAssertEqual(cfg.os, "darwin")
    }

    func testRunArguments() {
        let cli = TartCLI(binary: URL(fileURLWithPath: "/usr/bin/true"))
        var opts = RunOptions()
        opts.noGraphics = true
        opts.sharedDirectories = ["src:/Users/me/src"]
        XCTAssertEqual(cli.runArguments(name: "vm", options: opts),
                       ["run", "vm", "--suspendable", "--no-graphics", "--dir", "src:/Users/me/src"])
    }

    func testRunArgumentsSoftnet() {
        let cli = TartCLI(binary: URL(fileURLWithPath: "/usr/bin/true"))
        var opts = RunOptions()
        opts.softnet = true
        opts.bridgedInterface = "en0"
        opts.softnetAllow = ["192.168.1.0/24", "10.0.0.0/8"]
        opts.softnetExpose = ["2222:22"]
        XCTAssertEqual(cli.runArguments(name: "vm", options: opts),
                       ["run", "vm", "--suspendable", "--net-softnet",
                        "--net-softnet-allow", "192.168.1.0/24,10.0.0.0/8",
                        "--net-softnet-expose", "2222:22"])
    }
}
