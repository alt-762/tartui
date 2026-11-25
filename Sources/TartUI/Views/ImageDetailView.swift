import SwiftUI
import TartKit

struct ImageDetailView: View {
    @Environment(VMStore.self) private var store
    let image: TartVM
    @Binding var sheet: ActiveSheet?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill").font(.system(size: 36)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(image.name).font(.title3.bold()).textSelection(.enabled)
                        Text("OCI image (cached locally)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { sheet = .clone(source: image.name) } label: {
                        Label("Create VM from Image", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Section("Details") {
                LabeledContent("Disk", value: image.diskGB.map { "\($0) GB" } ?? "—")
                LabeledContent("Size on disk", value: image.sizeGB.map { "\($0) GB" } ?? "—")
                if let accessed = image.accessed { LabeledContent("Last accessed", value: accessed) }
            }
            Section {
                Button("Pull latest") { store.pull(image.name) }
                Button("Remove from cache…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(image.name)
        .confirmationDialog("Remove \(image.name)?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { store.delete(image.name) }
        } message: {
            Text("VMs already cloned from this image are not affected.")
        }
    }
}
