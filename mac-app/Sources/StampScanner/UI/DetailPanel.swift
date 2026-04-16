import SwiftUI
import GRDBQuery

struct DetailPanel: View {
    let selection: Set<String>
    let dbTick: Int
    @Query<StampsRequest> private var all: [StampRecord]

    init(selection: Set<String>, dbTick: Int) {
        self.selection = selection
        self.dbTick = dbTick
        _all = Query(constant: StampsRequest(filter: LibraryFilter(), externalTick: dbTick))
    }

    var body: some View {
        Group {
            switch resolved {
            case .none:
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Pick a stamp to see its details."))
            case .one(let record):
                SingleDetail(record: record)
            case .many(let records):
                MultiSummary(records: records)
            }
        }
        .padding()
    }

    private enum Resolved { case none, one(StampRecord), many([StampRecord]) }
    private var resolved: Resolved {
        let picked = all.filter { selection.contains($0.id) }
        switch picked.count {
        case 0: return .none
        case 1: return .one(picked[0])
        default: return .many(picked)
        }
    }
}

private struct SingleDetail: View {
    let record: StampRecord
    @State private var draft: StampRecord

    @State private var localRotationKey: Int = 0

    init(record: StampRecord) {
        self.record = record
        self._draft = State(initialValue: record)
    }

    private var displayURL: URL {
        let base = record.cropURL
        return URL(string: base.absoluteString + "?r=\(localRotationKey)") ?? base
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: displayURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    default: ProgressView().frame(height: 180)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onReceive(NotificationCenter.default.publisher(for: .stampCropRotated)) { note in
                    if (note.object as? String) == record.id {
                        localRotationKey &+= 1
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        try? StampStore.rotate(record, byDegrees: -90)
                    } label: {
                        Label("Left", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        try? StampStore.rotate(record, byDegrees: 180)
                    } label: {
                        Label("Flip", systemImage: "arrow.up.arrow.down")
                    }
                    Button {
                        try? StampStore.rotate(record, byDegrees: 90)
                    } label: {
                        Label("Right", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)

                if !record.issueTags.isEmpty || !record.dismissedIssueTags.isEmpty {
                    IssuesSection(record: record)
                }

                GroupBox("Identification") {
                    VStack(spacing: 8) {
                        Field("Country", text: bind(\.country))
                        NumField("Year", value: bindInt(\.year))
                        Field("Denomination", text: bind(\.denomination))
                        Field("Colour", text: bind(\.colour))
                        Field("Subject", text: bind(\.subject))
                        Field("Series", text: bind(\.series))
                    }
                }

                GroupBox("Usage") {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Status").frame(width: 90, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { draft.used },
                                set: { draft.used = $0; persist() }
                            )) {
                                Text("Unknown").tag(Bool?.none)
                                Text("Mint").tag(Bool?.some(false))
                                Text("Used").tag(Bool?.some(true))
                            }
                            .pickerStyle(.segmented)
                        }
                        Field("Cancel type", text: bind(\.cancelType))
                        Field("Printing", text: bind(\.printing))
                        Field("Overprint", text: bind(\.overprint))
                    }
                }

                GroupBox("Physical (manual)") {
                    VStack(spacing: 8) {
                        Field("Perf gauge", text: bind(\.perfGauge))
                        Field("Watermark", text: bind(\.watermark))
                        HStack {
                            Text("Gum").frame(width: 90, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { draft.gum ?? "" },
                                set: { draft.gum = $0.isEmpty ? nil : $0; persist() }
                            )) {
                                Text("—").tag("")
                                Text("MNH").tag("MNH")
                                Text("LH").tag("LH")
                                Text("OG").tag("OG")
                                Text("NG").tag("NG")
                                Text("RG").tag("RG")
                            }
                            .pickerStyle(.menu)
                        }
                        HStack {
                            Text("Condition").frame(width: 90, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { draft.condition ?? "" },
                                set: { draft.condition = $0.isEmpty ? nil : $0; persist() }
                            )) {
                                Text("—").tag("")
                                Text("Superb").tag("S")
                                Text("XF").tag("XF")
                                Text("VF").tag("VF")
                                Text("F-VF").tag("F-VF")
                                Text("F").tag("F")
                                Text("AVG").tag("AVG")
                            }
                            .pickerStyle(.menu)
                        }
                        Field("Catalogue ref", text: bind(\.catalogueRef))
                    }
                }

                GroupBox("Description") {
                    TextEditor(text: bind(\.description))
                        .frame(minHeight: 60)
                        .font(.callout)
                }

                GroupBox("Notes") {
                    TextEditor(text: bind(\.notes))
                        .frame(minHeight: 60)
                        .font(.callout)
                }

                // When the user wires in a Colnect API key, uncomment the
                // block below. Required by Colnect ToS clause 10.G:
                // "You are required to mention Colnect as a source of
                // information used for your product by including the
                // following statement on your application's website or
                // as a part of your application in a visible place:
                // 'Catalog information courtesy of Colnect, an online
                // collectors community.' and have a link to any page on
                // Colnect that you find most relevant."
                //
                // if record.catalogueRef?.starts(with: "Colnect") == true {
                //     HStack(spacing: 4) {
                //         Text("Catalog information courtesy of")
                //         Link("Colnect", destination: URL(string: "https://colnect.com/en/stamps")!)
                //         Text("— an online collectors community.")
                //     }
                //     .font(.caption2)
                //     .foregroundStyle(.tertiary)
                // }

                GroupBox("Capture") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("ID", record.id)
                        row("Captured", record.capturedAt.formatted(
                            date: .abbreviated, time: .shortened))
                        row("Confidence", String(format: "%.2f", record.confidence))
                        row("Crop", "\(record.cropW)×\(record.cropH)")
                        row("Oriented", record.oriented ? "yes" : "no")
                    }
                    .font(.caption.monospaced())
                }

                HStack {
                    Button {
                        draft.flagged.toggle(); persist()
                    } label: {
                        Label(draft.flagged ? "Unflag" : "Flag",
                              systemImage: draft.flagged ? "flag.slash" : "flag")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        try? StampStore.delete(record)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .onChange(of: record.id) { _, _ in draft = record }
    }

    private func persist() { try? StampStore.update(draft) }

    private func bind(_ key: WritableKeyPath<StampRecord, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: key] ?? "" },
            set: { draft[keyPath: key] = $0.isEmpty ? nil : $0; persist() }
        )
    }

    private func bindInt(_ key: WritableKeyPath<StampRecord, Int?>) -> Binding<Int?> {
        Binding(
            get: { draft[keyPath: key] },
            set: { draft[keyPath: key] = $0; persist() }
        )
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
    }
}

private struct IssuesSection: View {
    let record: StampRecord
    @State private var related: [StampRecord] = []

    private static let labels: [String: String] = [
        "duplicate": "Duplicate",
        "obscured":  "Obscured",
        "partial":   "Partial crop",
    ]

    var body: some View {
        GroupBox("Issues") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(record.issueTags, id: \.self) { tag in
                    issueRow(tag: tag, dismissed: false)
                }
                ForEach(record.dismissedIssueTags, id: \.self) { tag in
                    issueRow(tag: tag, dismissed: true)
                }

                // Related duplicates
                if !related.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text(record.duplicateOf != nil
                         ? "Duplicate of:"
                         : "This stamp's duplicates:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(related, id: \.id) { r in
                        RelatedRecordChip(record: r)
                    }
                }
            }
        }
        .onAppear(perform: loadRelated)
        .onChange(of: record.id) { _, _ in loadRelated() }
        .onChange(of: record.issueTags) { _, _ in loadRelated() }
    }

    private func issueRow(tag: String, dismissed: Bool) -> some View {
        HStack {
            Image(systemName: dismissed ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(dismissed ? .green : .orange)
            Text(Self.labels[tag] ?? tag.capitalized)
                .strikethrough(dismissed)
            Spacer()
            if dismissed {
                Button("Re-enable") {
                    try? IssueDetector.unDismissTag(tag, on: record)
                }
                .controlSize(.small)
                .help("Allow the detector to flag this issue again")
            } else {
                Button("Not actually \(Self.labels[tag]?.lowercased() ?? tag)") {
                    try? IssueDetector.dismissTag(tag, on: record)
                }
                .controlSize(.small)
                .help("Remove this flag and prevent the detector from re-adding it")
            }
        }
        .font(.callout)
    }

    private func loadRelated() {
        related = (try? IssueDetector.relatedDuplicates(of: record)) ?? []
    }
}

private struct RelatedRecordChip: View {
    let record: StampRecord
    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: record.cropURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: Color.gray.opacity(0.2)
                }
            }
            .frame(width: 48, height: 48)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text([record.country, record.year.map(String.init),
                       record.denomination]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                    .font(.caption).lineLimit(1)
                Text(record.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(role: .destructive) {
                try? StampStore.delete(record)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this related record")
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct Field: View {
    let label: String
    @Binding var text: String
    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }
    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(label, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

private struct NumField: View {
    let label: String
    @Binding var value: Int?
    init(_ label: String, value: Binding<Int?>) {
        self.label = label
        self._value = value
    }
    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct MultiSummary: View {
    let records: [StampRecord]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(records.count) stamps selected").font(.title3).bold()
            HStack {
                Button { flag(true) } label: { Label("Flag all", systemImage: "flag") }
                Button { flag(false) } label: { Label("Unflag all", systemImage: "flag.slash") }
            }
            Button(role: .destructive) {
                for r in records { try? StampStore.delete(r) }
            } label: {
                Label("Delete \(records.count) stamps", systemImage: "trash")
            }
            Spacer()
        }
    }
    private func flag(_ value: Bool) {
        for r in records {
            var u = r; u.flagged = value; try? StampStore.update(u)
        }
    }
}
