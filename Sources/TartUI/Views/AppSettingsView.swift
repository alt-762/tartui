import SwiftUI

/// The app's Settings window (⌘,). VM hardware settings live on each VM's detail page.
struct AppSettingsView: View {
    @Environment(VMStore.self) private var store
    @AppStorage("tartPath") private var tartPath = ""
    @State private var confirmPrune = false

    var body: some View {
        Form {
            Section("tart CLI") {
                TextField("Path override", text: $tartPath, prompt: Text("/opt/homebrew/bin/tart"))
                LabeledContent("Detected version", value: store.tartVersion ?? "not found")
                Button("Re-detect") { store.reloadCLI() }
            }
            Section("Cache") {
                Button("Prune cached images…", role: .destructive) { confirmPrune = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .confirmationDialog("Prune tart caches?", isPresented: $confirmPrune) {
            Button("Prune", role: .destructive) { store.prune() }
        } message: {
            Text("Removes cached OCI images and IPSW downloads. Local VMs are kept.")
        }
    }
}
