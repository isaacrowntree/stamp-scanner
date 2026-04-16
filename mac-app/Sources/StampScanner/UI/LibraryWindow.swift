import SwiftUI

struct LibraryWindow: View {
    @EnvironmentObject var server: PhoneIngestServer
    @EnvironmentObject var worker: WorkerLauncher

    @State private var filter = LibraryFilter()
    @State private var selection: Set<String> = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showInspector = false
    @State private var vlmRunning = false
    @State private var colnectRunning = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(filter: $filter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            LibraryGridView(
                filter: filter,
                selection: $selection,
                highlightJobId: nil
            )
            .toolbar {
                LibraryToolbar(
                    filter: $filter,
                    selection: $selection,
                    showInspector: $showInspector,
                    vlmRunning: $vlmRunning,
                    colnectRunning: $colnectRunning
                )
            }
            .inspector(isPresented: $showInspector) {
                DetailPanel(selection: selection)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
            }
        }
        .overlay(alignment: .bottom) {
            if worker.health != .healthy { WorkerHealthBanner(health: worker.health) }
        }
        .onChange(of: selection) { _, new in
            if !new.isEmpty { showInspector = true }
        }
    }
}

private struct WorkerHealthBanner: View {
    let health: WorkerLauncher.Health
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.8), in: Capsule())
        .padding(.bottom, 14)
    }
    private var color: Color {
        switch health {
        case .starting: return .yellow
        case .stale:    return .orange
        default:        return .red
        }
    }
    private var label: String {
        switch health {
        case .starting: return "SAM 3 starting…"
        case .stale:    return "SAM 3 heartbeat stale"
        case .dead:     return "SAM 3 offline"
        case .healthy:  return ""
        }
    }
}
