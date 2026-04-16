import SwiftUI
import GRDBQuery

struct LibraryGridView: View {
    let filter: LibraryFilter
    @Binding var selection: Set<String>
    let highlightJobId: String?
    let dbTick: Int

    @Query<StampsRequest> private var records: [StampRecord]

    init(filter: LibraryFilter,
         selection: Binding<Set<String>>,
         highlightJobId: String?,
         dbTick: Int) {
        self.filter = filter
        self._selection = selection
        self.highlightJobId = highlightJobId
        self.dbTick = dbTick
        // `Query(constant:)` re-fetches when the request changes. Plain
        // `Query(request)` captures the initial value and never updates —
        // that's why our sort picker and search field were dead.
        _records = Query(constant: StampsRequest(filter: filter, externalTick: dbTick))
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
                                isHighlighted: record.jobId == highlightJobId && highlightJobId != nil,
                                onDelete: {
                                    try? StampStore.delete(record)
                                    selection.remove(record.id)
                                }
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
        case .partials:     return "No partial crops"
        case .obscured:     return "No obscured crops"
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

private struct CellActionBar: View {
    let record: StampRecord
    let onDelete: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            actionButton("arrow.counterclockwise", tip: "Rotate left") {
                try? StampStore.rotate(record, byDegrees: -90)
            }
            actionButton("arrow.up.arrow.down", tip: "Flip 180°") {
                try? StampStore.rotate(record, byDegrees: 180)
            }
            actionButton("arrow.clockwise", tip: "Rotate right") {
                try? StampStore.rotate(record, byDegrees: 90)
            }
            Divider().frame(height: 16).overlay(.white.opacity(0.3))
            actionButton("trash", tip: "Delete", destructive: true) {
                onDelete()
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(.black.opacity(0.75), in: Capsule())
    }
    private func actionButton(_ icon: String, tip: String,
                               destructive: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(destructive ? .red : .white)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

private struct GridCell: View {
    let record: StampRecord
    let isSelected: Bool
    let isHighlighted: Bool
    let onDelete: () -> Void
    @State private var hovering = false
    /// Local cache buster — bumped when StampStore.rotate posts for this
    /// record's id. Keeps the disruption scoped to this one cell so the
    /// grid layout doesn't reshuffle on rotation.
    @State private var localRotationKey: Int = 0

    private var displayURL: URL {
        let base = record.cropURL
        return URL(string: base.absoluteString + "?r=\(localRotationKey)") ?? base
    }

    var body: some View {
        // Outer container — white frame + selection stroke + shadow. The
        // image + overlays live inside so hover chrome hugs the image
        // itself, not the whole grid cell (previous bug: action bar
        // floated at the bottom of the cell, far from the cursor).
        AsyncImage(url: displayURL) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFit()
            case .failure:
                Image(systemName: "photo").foregroundStyle(.secondary)
                    .frame(minHeight: 100)
            default:
                ProgressView().controlSize(.small).frame(minHeight: 100)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            if record.flagged {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange).padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if record.confidence < 0.7 {
                Text(String(format: "%.0f%%", record.confidence * 100))
                    .font(.caption2).bold().monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if hovering {
                CellActionBar(record: record, onDelete: onDelete)
                    .padding(8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor :
                               (isHighlighted ? Color.yellow : Color.clear),
                               lineWidth: isSelected || isHighlighted ? 3 : 0)
        )
        .shadow(color: .black.opacity(hovering ? 0.25 : 0.10),
                radius: hovering ? 6 : 2, y: hovering ? 3 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        .onReceive(NotificationCenter.default.publisher(for: .stampCropRotated)) { note in
            if (note.object as? String) == record.id {
                localRotationKey &+= 1
            }
        }
    }
}
