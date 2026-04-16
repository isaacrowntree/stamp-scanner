import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct StampScannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var worker = WorkerLauncher()
    @StateObject private var phoneServer = PhoneIngestServer()
    @StateObject private var dbWatcher = DatabaseWatcher()
    @StateObject private var issueDetector = IssueDetector()

    @State private var showPairing = false

    var body: some Scene {
        WindowGroup("Stamp Scanner") {
            RootView(showPairing: $showPairing)
                .environmentObject(worker)
                .environmentObject(phoneServer)
                .environmentObject(dbWatcher)
                .environmentObject(issueDetector)
                .installDatabaseContext()
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    Paths.ensureDirs()
                    // Touch the DB so migrations run before any view attempts
                    // to observe it.
                    _ = LibraryDatabase.shared
                    worker.start()
                    dbWatcher.start()
                    phoneServer.start(mode: .lan)
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Library") {
                Button("Pair iPhone…") { showPairing = true }
                    .keyboardShortcut("p")
                Divider()
                Button("Restart SAM 3 worker") {
                    worker.stop(); worker.start()
                }
            }
        }
    }
}

private struct RootView: View {
    @Binding var showPairing: Bool
    var body: some View {
        Group {
            if PairingStore.currentSecret == nil {
                WelcomeView()
            } else {
                LibraryWindow()
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingSheet(visible: $showPairing)
                .frame(minWidth: 420, minHeight: 320)
        }
    }
}
