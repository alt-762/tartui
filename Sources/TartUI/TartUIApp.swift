import SwiftUI
import AppKit

@main
struct TartUIApp: App {
    @State private var store = VMStore()

    init() {
        // When launched via `swift run` there is no bundle, so make sure we get a Dock icon and focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Tart") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .task { store.startPolling() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            AppSettingsView()
                .environment(store)
        }
    }
}
