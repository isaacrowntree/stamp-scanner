import SwiftUI
import GRDBQuery

struct LibraryGridView: View {
    let filter: LibraryFilter
    @Binding var selection: Set<String>
    let highlightJobId: String?

    @Query<StampsRequest> private var records: [StampRecord]

    init(filter: LibraryFilter,
         selection: Binding<Set<String>>,
         highlightJobId: String?) {
        self.filter = filter
        self._selection = selection
        self.highlightJobId = highlightJobId
        _records = Query(StampsRequest(filter: filter))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if records.isEmpty {
                    emptyState.padding(.top, 120)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)],
                              spacing: 14) {
                        ForEach(records) { record in
                            GridCell(
                                record: record,
                                isSelected: selection.contains(record.id),
                                isHighlighted: record.jobId == highlightJobId && highlightJobId != nil
                            )
                            .id(record.id)
                            .onTapGesture(count: 2) { openQuickLook(record) }
                            .onTapGesture { toggle(record.id) }
                            .contextMenu { cellMenu(record) }
                        }
                    }
                    .padding(16)
                }
            }
            .onChange(of: highlightJobId) { _, new in
                guard let jobId = new,
                      let first = records.first(where: { $0.jobId == jobId }) else { return }
                withAnimation(.easeOut(duration: 0.4)) {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52)).foregroundStyle(.tertiary)
            Text(emptyTitle).font(.title3)
            Text(emptySubtitle).foregroundStyle(.secondary).font(.callout)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
    private var emptyTitle: String {
        switch filter.folder {
        case .all:          return "No stamps yet"
        case .recent:       return "Nothing scanned today"
        case .unidentified: return "Everything's identified"
        case .flagged:      return "Nothing flagged"
        case .duplicates:   return "No duplicates found"
        }
    }
    private var emptySubtitle: String {
        filter.folder == .all
            ? "Scan with your paired iPhone and your stamps will appear here."
            : "Try another folder or adjust the search."
    }

    private func toggle(_ id: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    @ViewBuilder
    private func cellMenu(_ record: StampRecord) -> some View {
        Button("Rotate Left") { try? StampStore.rotate(record, byDegrees: -90) }
        Button("Rotate Right") { try? StampStore.rotate(record, byDegrees: 90) }
        Button("Flip 180°") { try? StampStore.rotate(record, byDegrees: 180) }
        Divider()
        Button(record.flagged ? "Unflag" : "Flag") {
            var r = record; r.flagged.toggle()
            try? StampStore.update(r)
        }
        Button("Reveal Source in Finder") {
            if let url = record.sourceURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }.disabled(record.sourceURL == nil)
        Divider()
        Button("Delete", role: .destructive) {
            try? StampStore.delete(record)
            selection.remove(record.id)
        }
    }

    private func openQuickLook(_ record: StampRecord) {
        NSWorkspace.shared.open(record.cropURL)
    }
}

private struct RotateButtons: View {
    let record: StampRecord
    var body: some View {
        HStack(spacing: 4) {
            rotateButton("arrow.counterclockwise", degrees: -90)
            rotateButton("arrow.up.arrow.down", degrees: 180)
            rotateButton("arrow.clockwise", degrees: 90)
        }
        .padding(4)
        .background(.black.opacity(0.55), in: Capsule())
    }
    private func rotateButton(_ icon: String, degrees: Int) -> some View {
        Button {
            try? StampStore.rotate(record, byDegrees: degrees)
        } label: {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }
}

private struct GridCell: View {
    let record: StampRecord
    let isSelected: Bool
    let isHighlighted: Bool
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AsyncImage(url: record.cropDisplayURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                default: ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .padding(8)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor :
                                   (isHighlighted ? Color.yellow : Color.clear),
                                   lineWidth: isSelected || isHighlighted ? 3 : 0)
            )
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.10),
                    radius: hovering ? 6 : 2, y: hovering ? 3 : 1)

            if record.flagged {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange).padding(6)
            }
            if record.confidence < 0.7 {
                Text(String(format: "%.0f%%", record.confidence * 100))
                    .font(.caption2).bold().monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .padding(6)
            }

            if hovering {
                RotateButtons(record: record)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
    }
}
