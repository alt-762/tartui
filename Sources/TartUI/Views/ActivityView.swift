import SwiftUI

/// Progress for long-running tart operations (create, clone, pull, push).
struct ActivityView: View {
    @Environment(VMStore.self) private var store
    @State private var expanded: Set<UUID> = []

    var body: some View {
        Group {
            if store.operations.isEmpty {
                ContentUnavailableView("No activity", systemImage: "tray",
                                       description: Text("Creates, clones, pulls and pushes show up here."))
            } else {
                List(store.operations) { op in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            statusIcon(op)
                            Text(op.title).font(.headline)
                            Spacer()
                            if op.isRunning {
                                Button("Cancel") { store.cancel(op) }
                            }
                            Button {
                                if expanded.contains(op.id) { expanded.remove(op.id) } else { expanded.insert(op.id) }
                            } label: {
                                Image(systemName: expanded.contains(op.id) ? "chevron.up" : "chevron.down")
                            }
                            .buttonStyle(.borderless)
                        }
                        if case let .failed(message) = op.status {
                            Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        } else if !op.lastLine.isEmpty {
                            Text(op.lastLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if expanded.contains(op.id) {
                            ScrollView {
                                Text(op.lines.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                            .padding(6)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Clear Finished") { store.clearFinishedOperations() }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ op: TartOperation) -> some View {
        switch op.status {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
