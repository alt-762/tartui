import SwiftUI
import TartKit

enum SidebarItem: Hashable {
    case vm(String)
    case image(String)
    case activity
}

enum ActiveSheet: Identifiable {
    case create
    case clone(source: String)
    case pull
    case push(local: String)
    case login

    var id: String {
        switch self {
        case .create: "create"
        case let .clone(s): "clone-\(s)"
        case .pull: "pull"
        case let .push(l): "push-\(l)"
        case .login: "login"
        }
    }
}

struct ContentView: View {
    @Environment(VMStore.self) private var store
    @State private var selection: SidebarItem?
    @State private var sheet: ActiveSheet?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Virtual Machines") {
                    ForEach(store.localVMs) { vm in
                        VMRow(vm: vm, os: store.guestOS(for: vm)).tag(SidebarItem.vm(vm.name))
                            .contextMenu { vmMenu(vm) }
                    }
                    if store.localVMs.isEmpty {
                        if store.hasLoaded {
                            Text("No VMs yet").foregroundStyle(.secondary)
                        } else {
                            LoadingRow(text: "Loading VMs…")
                        }
                    }
                }
                Section("Images") {
                    ForEach(store.ociImages) { image in
                        ImageRow(image: image, os: store.guestOS(for: image)).tag(SidebarItem.image(image.name))
                            .contextMenu { imageMenu(image) }
                    }
                    if store.ociImages.isEmpty {
                        if store.hasLoaded {
                            Text("No pulled images").foregroundStyle(.secondary)
                        } else {
                            LoadingRow(text: "Loading images…")
                        }
                    }
                }
                Section {
                    Label {
                        HStack {
                            Text("Activity")
                            Spacer()
                            let running = store.operations.filter(\.isRunning).count
                            if running > 0 {
                                Text("\(running)").monospacedDigit()
                                    .padding(.horizontal, 6)
                                    .background(.tint, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    } icon: { Image(systemName: "list.bullet.rectangle") }
                    .tag(SidebarItem.activity)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            switch selection {
            case let .vm(name):
                if let vm = store.vms.first(where: { $0.source == .local && $0.name == name }) {
                    VMDetailView(vm: vm, sheet: $sheet)
                } else {
                    ContentUnavailableView("VM not found", systemImage: "questionmark.square.dashed")
                }
            case let .image(name):
                if let image = store.vms.first(where: { $0.source == .oci && $0.name == name }) {
                    ImageDetailView(image: image, sheet: $sheet)
                } else {
                    ContentUnavailableView("Image not found", systemImage: "questionmark.square.dashed")
                }
            case .activity:
                ActivityView()
            case nil:
                ContentUnavailableView {
                    Label("Tart", systemImage: "desktopcomputer")
                } description: {
                    Text(store.tartVersion.map { "tart \($0)" } ?? "Select a VM or image")
                } actions: {
                    Button("New VM…") { sheet = .create }
                    Button("Pull Image…") { sheet = .pull }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { sheet = .create } label: { Label("New VM", systemImage: "plus") }
                    .help("Create a new VM")
                Button { sheet = .pull } label: { Label("Pull", systemImage: "arrow.down.circle") }
                    .help("Pull an image from a registry")
                Button { sheet = .login } label: { Label("Registry Login", systemImage: "person.badge.key") }
                    .help("Log in to an OCI registry")
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing {
                        // Same footprint as the icon so the toolbar doesn't shift.
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help(store.isRefreshing ? "Refreshing…" : "Refresh the VM list")
                .disabled(store.isRefreshing)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create: CreateVMSheet()
            case let .clone(source): CloneSheet(source: source)
            case .pull: PullImageSheet()
            case let .push(local): PushSheet(localName: local)
            case .login: LoginSheet()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showLogin)) { _ in sheet = .login }
        .alert(
            "Set up Softnet?",
            isPresented: Binding(
                get: { store.pendingSoftnetSetup != nil },
                set: { if !$0 { store.pendingSoftnetSetup = nil } }
            ),
            presenting: store.pendingSoftnetSetup
        ) { pending in
            Button("Set Up and Start") { store.completeSoftnetSetup(pending) }
            Button("Cancel", role: .cancel) { store.pendingSoftnetSetup = nil }
        } message: { pending in
            Text("Softnet isolates \(pending.vm)'s network. It needs administrator rights once: macOS will ask for your password to set the setuid bit on \(pending.softnetPath). This is what `tart run --net-softnet` asks for in Terminal.")
        }
        .alert("Tart error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private func vmMenu(_ vm: TartVM) -> some View {
        if vm.isRunning {
            Button("Stop") { store.stop(vm.name) }
            Button("Suspend") { store.suspend(vm.name) }
        } else {
            Button("Start") { store.start(vm.name) }
        }
        Button("Clone…") { sheet = .clone(source: vm.name) }
        Button("Push…") { sheet = .push(local: vm.name) }
        Divider()
        Button("Delete", role: .destructive) { store.delete(vm.name) }
            .disabled(vm.isRunning)
    }

    @ViewBuilder
    private func imageMenu(_ image: TartVM) -> some View {
        Button("Clone to VM…") { sheet = .clone(source: image.name) }
        Divider()
        Button("Delete", role: .destructive) { store.delete(image.name) }
    }
}

extension GuestOS {
    /// SF Symbol for the guest OS. There's no Linux logo in SF Symbols, so Linux uses a terminal.
    var symbolName: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "terminal"
        case .unknown: "desktopcomputer"
        }
    }
}

struct VMRow: View {
    let vm: TartVM
    let os: GuestOS

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: os.symbolName)
                .foregroundStyle(vm.isRunning ? .green : vm.isSuspended ? .orange : .secondary)
                .help(os.displayName)
        }
    }

    private var subtitle: String {
        os == .unknown ? vm.state.capitalized : "\(os.displayName) · \(vm.state.capitalized)"
    }
}

struct ImageRow: View {
    let image: TartVM
    let os: GuestOS

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(image.name).lineLimit(1).truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: os == .unknown ? "shippingbox" : os.symbolName)
                .help(os.displayName)
        }
    }

    private var subtitle: String? {
        let parts = [os == .unknown ? nil : os.displayName, image.sizeGB.map { "\($0) GB" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct LoadingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
