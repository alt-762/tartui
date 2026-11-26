import SwiftUI
import AppKit
import TartKit

struct VMDetailView: View {
    @Environment(VMStore.self) private var store
    let vm: TartVM
    @Binding var sheet: ActiveSheet?

    @State private var runOptions = RunOptions()
    @State private var sharedDir = ""
    @State private var softnetAllow = ""
    @State private var softnetExpose = ""
    @State private var ip: String?
    @State private var confirmDelete = false

    // Editable settings (populated from `tart get`)
    @State private var cpu = 4
    @State private var memoryMB = 8192
    @State private var diskGB = 50
    @State private var display = ""
    @State private var loadedConfig: TartVMConfig?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: store.guestOS(for: vm).symbolName)
                        .font(.system(size: 36))
                        .foregroundStyle(vm.isRunning ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(vm.name).font(.title2.bold())
                        Text("\(vm.state.capitalized) · \(osLabel)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    lifecycleButtons
                }
                if vm.isRunning {
                    LabeledContent("IP address") {
                        HStack {
                            Text(ip ?? "…").textSelection(.enabled).monospaced()
                            if let ip {
                                Button("Copy SSH") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("ssh admin@\(ip)", forType: .string)
                                }
                            }
                        }
                    }
                }
            }

            Section("Run options") {
                Toggle("Headless (no graphics window)", isOn: $runOptions.noGraphics)
                Toggle("Boot into recovery", isOn: $runOptions.recovery)
                HStack {
                    TextField("Shared folder (name:/path[:ro])", text: $sharedDir)
                    Button("Choose…", action: chooseSharedFolder)
                }
                Toggle("Isolate network (Softnet)", isOn: $runOptions.softnet)
                    .help("Runs with --net-softnet: the VM can reach the internet but not your LAN or other VMs. tart may ask for your password the first time to set up the softnet helper.")
                if runOptions.softnet {
                    TextField("Allow networks (CIDRs, comma-separated)", text: $softnetAllow, prompt: Text("192.168.1.0/24"))
                        .help("--net-softnet-allow: networks the VM may still reach")
                    TextField("Expose ports (host:guest, comma-separated)", text: $softnetExpose, prompt: Text("2222:22, 8080:80"))
                        .help("--net-softnet-expose: forward host ports into the VM")
                }
            }
            .disabled(vm.isRunning)

            Section("Hardware") {
                Stepper("CPU cores: \(cpu)", value: $cpu, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                Stepper("Memory: \(memoryMB / 1024) GB", value: $memoryMB, in: 1024...131072, step: 1024)
                Stepper("Disk: \(diskGB) GB", value: $diskGB, in: max(10, loadedConfig?.diskGB ?? 10)...2048, step: 10)
                    .help("Disks can only grow, not shrink")
                TextField("Display (e.g. 1920x1080)", text: $display)
                HStack {
                    Spacer()
                    Button("Revert") { if let c = loadedConfig { apply(c) } }
                        .disabled(!hasChanges)
                    Button("Apply") {
                        guard let c = loadedConfig else { return }
                        store.applySettings(
                            vm.name,
                            cpu: cpu != c.cpu ? cpu : nil,
                            memoryMB: memoryMB != c.memoryMB ? memoryMB : nil,
                            diskSizeGB: diskGB != c.diskGB ? diskGB : nil,
                            display: display != c.display ? display : nil
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                }
            }
            .disabled(vm.isRunning)

            Section("Storage") {
                LabeledContent("Allocated disk", value: vm.diskGB.map { "\($0) GB" } ?? "—")
                LabeledContent("Size on disk", value: vm.sizeGB.map { "\($0) GB" } ?? "—")
                if let accessed = vm.accessed { LabeledContent("Last accessed", value: accessed) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(vm.name)
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Clone…") { sheet = .clone(source: vm.name) }
                Button("Push…") { sheet = .push(local: vm.name) }
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .disabled(vm.isRunning)
            }
        }
        .confirmationDialog("Delete \(vm.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(vm.name) }
        } message: {
            Text("This permanently removes the VM and its disk.")
        }
        .task(id: vm.name) {
            await store.loadConfig(for: vm.name)
            if let c = store.configs[vm.name] { apply(c) }
        }
        .onChange(of: store.configs[vm.name]) { _, new in
            if let new { apply(new) }
        }
        .task(id: "\(vm.name)-\(vm.state)") {
            ip = nil
            if vm.isRunning { ip = await store.ip(for: vm.name) }
        }
    }

    private var osLabel: String {
        let os = store.guestOS(for: vm)
        return os == .unknown ? (loadedConfig?.os ?? "—") : os.displayName
    }

    @ViewBuilder
    private var lifecycleButtons: some View {
        if vm.isRunning {
            Button { store.suspend(vm.name) } label: { Label("Suspend", systemImage: "pause.fill") }
            Button { store.stop(vm.name) } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.borderedProminent).tint(.red)
        } else {
            Button {
                var opts = runOptions
                if !sharedDir.isEmpty { opts.sharedDirectories = [sharedDir] }
                opts.softnetAllow = Self.splitList(softnetAllow)
                opts.softnetExpose = Self.splitList(softnetExpose)
                store.start(vm.name, options: opts)
            } label: { Label(vm.isSuspended ? "Resume" : "Start", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Splits a comma- or whitespace-separated field into trimmed, non-empty items.
    static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    private var hasChanges: Bool {
        guard let c = loadedConfig else { return false }
        return cpu != c.cpu || memoryMB != c.memoryMB || diskGB != c.diskGB || display != c.display
    }

    private func apply(_ c: TartVMConfig) {
        loadedConfig = c
        cpu = c.cpu
        memoryMB = c.memoryMB
        diskGB = c.diskGB
        display = c.display
    }

    private func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            sharedDir = "\(url.lastPathComponent):\(url.path)"
        }
    }
}
