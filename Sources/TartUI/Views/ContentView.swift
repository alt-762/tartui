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
                        VMRow(vm: vm).tag(SidebarItem.vm(vm.name))
                            .contextMenu { vmMenu(vm) }
                    }
                    if store.localVMs.isEmpty {
                        Text("No VMs yet").foregroundStyle(.secondary)
                    }
                }
                Section("Images") {
                    ForEach(store.ociImages) { image in
                        ImageRow(image: image).tag(SidebarItem.image(image.name))
                            .contextMenu { imageMenu(image) }
                    }
                    if store.ociImages.isEmpty {
                        Text("No pulled images").foregroundStyle(.secondary)
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
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
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

struct VMRow: View {
    let vm: TartVM

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name)
                Text(vm.state.capitalized).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(vm.isRunning ? .green : vm.isSuspended ? .orange : .secondary)
        }
    }
}

struct ImageRow: View {
    let image: TartVM

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(image.name).lineLimit(1).truncationMode(.middle)
                if let size = image.sizeGB {
                    Text("\(size) GB").font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "shippingbox")
        }
    }
}
