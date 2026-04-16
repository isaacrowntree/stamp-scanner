import SwiftUI
import GRDBQuery

struct SidebarView: View {
    @Binding var filter: LibraryFilter
    @Query(StampCountsRequest()) private var counts: StampCountsRequest.Counts
    @EnvironmentObject var server: PhoneIngestServer
    @State private var pairingCode: String = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(SmartFolder.allCases) { folder in
                    Button {
                        filter.folder = folder
                    } label: {
                        HStack {
                            Label(folder.label, systemImage: folder.systemImage)
                            Spacer()
                            if count(for: folder) > 0 {
                                Text("\(count(for: folder))")
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        filter.folder == folder
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
                }
            }
            .listStyle(.sidebar)

            Divider()
            iphoneSection
        }
        .onAppear { refreshCode() }
    }

    private func count(for folder: SmartFolder) -> Int {
        switch folder {
        case .all:          return counts.all
        case .recent:       return counts.recent
        case .unidentified: return counts.unidentified
        case .flagged:      return counts.flagged
        case .duplicates:   return 0
        }
    }

    private var iphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(server.jobCount > 0 ? .green : .secondary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PairingStore.peerName ?? "Not paired")
                        .font(.caption).bold()
                    Text(server.jobCount > 0
                         ? "\(server.jobCount) uploads"
                         : "Waiting…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Pairing code")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(formatted(pairingCode))
                        .font(.system(.title3, design: .monospaced).bold())
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        let secret = PairingStore.rotateSecret()
                        pairingCode = PairingStore.pairingCode(for: secret)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Rotate code (unpairs current iPhone)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func formatted(_ c: String) -> String {
        guard c.count == 6 else { return c }
        return "\(c.prefix(3)) \(c.suffix(3))"
    }

    private func refreshCode() {
        let secret = PairingStore.currentSecret ?? PairingStore.rotateSecret()
        pairingCode = PairingStore.pairingCode(for: secret)
    }
}
