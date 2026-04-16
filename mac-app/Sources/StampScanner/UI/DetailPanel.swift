import SwiftUI
import GRDBQuery

struct DetailPanel: View {
    let selection: Set<String>
    @Query<StampsRequest> private var all: [StampRecord]

    init(selection: Set<String>) {
        self.selection = selection
        _all = Query(StampsRequest(filter: LibraryFilter()))
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

    init(record: StampRecord) {
        self.record = record
        self._draft = State(initialValue: record)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: record.cropDisplayURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    default: ProgressView().frame(height: 180)
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))

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
