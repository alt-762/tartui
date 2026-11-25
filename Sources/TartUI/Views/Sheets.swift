import SwiftUI
import AppKit
import TartKit
import UniformTypeIdentifiers

/// Common chrome for the small modal forms.
private struct SheetScaffold<Content: View>: View {
    let title: String
    let confirmTitle: String
    let canConfirm: Bool
    let onConfirm: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding([.top, .horizontal])
            Form { content }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { onConfirm(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            .padding()
        }
        .frame(width: 480)
    }
}

private func isValidName(_ s: String) -> Bool {
    !s.isEmpty && s.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
}

// MARK: - Create

struct CreateVMSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case image = "From registry image"
        case macOS = "macOS (IPSW)"
        case linux = "Linux (empty)"
        var id: String { rawValue }
    }

    @Environment(VMStore.self) private var store
    @State private var name = ""
    @State private var kind: Kind = .image
    @State private var imageRef = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
    @State private var ipsw = "latest"
    @State private var diskGB = 50

    var body: some View {
        SheetScaffold(title: "New Virtual Machine", confirmTitle: "Create", canConfirm: canCreate, onConfirm: create) {
            TextField("Name", text: $name)
            Picker("Source", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            switch kind {
            case .image:
                TextField("Image", text: $imageRef)
                Text("Clones a prebuilt image. Fastest way to get a working VM.")
                    .font(.caption).foregroundStyle(.secondary)
            case .macOS:
                HStack {
                    TextField("IPSW", text: $ipsw)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.init(filenameExtension: "ipsw")!]
                        if panel.runModal() == .OK, let url = panel.url { ipsw = url.path }
                    }
                }
                Text("\"latest\" downloads the newest supported macOS. Takes a while.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 20...2048, step: 10)
            case .linux:
                Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 10...2048, step: 10)
                Text("Creates an empty Linux VM. Boot an installer ISO with a shared disk afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canCreate: Bool {
        isValidName(name) && (kind != .image || !imageRef.isEmpty) && (kind != .macOS || !ipsw.isEmpty)
    }

    private func create() {
        switch kind {
        case .image: store.clone(source: imageRef, newName: name)
        case .macOS: store.create(name: name, source: .macOSIPSW(ipsw), diskSizeGB: diskGB)
        case .linux: store.create(name: name, source: .linux, diskSizeGB: diskGB)
        }
    }
}

// MARK: - Clone

struct CloneSheet: View {
    @Environment(VMStore.self) private var store
    let source: String
    @State private var newName = ""

    var body: some View {
        SheetScaffold(title: "Clone \(source)", confirmTitle: "Clone", canConfirm: isValidName(newName), onConfirm: { store.clone(source: source, newName: newName) }) {
            LabeledContent("Source", value: source)
            TextField("New VM name", text: $newName)
        }
    }
}

// MARK: - Pull

struct PullImageSheet: View {
    @Environment(VMStore.self) private var store
    @State private var ref = "ghcr.io/cirruslabs/macos-sequoia-base:latest"

    private let suggestions = [
        "ghcr.io/cirruslabs/macos-sequoia-base:latest",
        "ghcr.io/cirruslabs/macos-sequoia-xcode:latest",
        "ghcr.io/cirruslabs/macos-sonoma-base:latest",
        "ghcr.io/cirruslabs/ubuntu:latest",
        "ghcr.io/cirruslabs/debian:latest",
    ]

    var body: some View {
        SheetScaffold(title: "Pull Image", confirmTitle: "Pull", canConfirm: !ref.isEmpty, onConfirm: { store.pull(ref) }) {
            TextField("Image reference", text: $ref)
            Picker("Suggestions", selection: $ref) {
                ForEach(suggestions, id: \.self) { Text($0).tag($0) }
                if !suggestions.contains(ref) { Text("Custom").tag(ref) }
            }
            Button("Log in to a registry…") {
                NotificationCenter.default.post(name: .showLogin, object: nil)
            }
            .buttonStyle(.link)
        }
    }
}

// MARK: - Push

struct PushSheet: View {
    @Environment(VMStore.self) private var store
    let localName: String
    @State private var remote = ""

    var body: some View {
        SheetScaffold(title: "Push \(localName)", confirmTitle: "Push", canConfirm: remote.contains("/"), onConfirm: { store.push(localName, to: remote) }) {
            TextField("Remote (e.g. ghcr.io/you/\(localName):latest)", text: $remote)
            Text("The VM must be stopped. Log in to the registry first if it's private.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Login

struct LoginSheet: View {
    @Environment(VMStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var host = "ghcr.io"
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Registry Login").font(.headline).padding([.top, .horizontal])
            Form {
                TextField("Registry host", text: $host)
                TextField("Username", text: $username)
                SecureField("Password or token", text: $password)
            }
            .formStyle(.grouped)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Log In") {
                    busy = true
                    Task {
                        let ok = await store.login(host: host, username: username, password: password)
                        busy = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || host.isEmpty || username.isEmpty || password.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
    }
}

extension Notification.Name {
    static let showLogin = Notification.Name("TartUI.showLogin")
}
