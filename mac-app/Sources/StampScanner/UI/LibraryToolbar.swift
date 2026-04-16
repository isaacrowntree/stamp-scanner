import SwiftUI

struct LibraryToolbar: ToolbarContent {
    @Binding var filter: LibraryFilter
    @Binding var selection: Set<String>
    @Binding var showInspector: Bool
    @Binding var vlmRunning: Bool
    @Binding var colnectRunning: Bool
    @EnvironmentObject var issueDetector: IssueDetector

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TextField("Search", text: $filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 260)
                .help("Search country, year, denomination, notes")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            iconButton(
                icon: "sparkles.rectangle.stack",
                tip: "Identify unprocessed stamps via Qwen3-VL (slow, ~1 min each)",
                busy: vlmRunning,
                action: runVLM
            )

            iconButton(
                icon: "exclamationmark.triangle",
                tip: "Find quality issues — duplicates, obscured, partials (Apple Vision, ~1 s each)",
                busy: issueDetector.running,
                busyProgress: issueDetector.running ? issueDetector.progress : nil,
                action: issueDetector.runAll
            )

            iconButton(
                icon: "books.vertical",
                tip: "Match identified stamps to Colnect catalogue (requires COLNECT_API_KEY)",
                busy: colnectRunning,
                action: runColnect
            )

            Picker(selection: $filter.sort) {
                ForEach(SortOrder.allCases, id: \.self) { s in
                    Text(s.label).tag(s)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            .help("Sort order")

            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: showInspector ? "sidebar.right" : "sidebar.trailing")
            }
            .help(showInspector ? "Hide inspector" : "Show inspector")
        }
    }

    /// Icon-only toolbar button — macOS shows the `help` string as a
    /// tooltip reliably when the Button's label has no visible text.
    /// Labels-with-text suppress the tooltip in SwiftUI toolbars.
    @ViewBuilder
    private func iconButton(icon: String, tip: String,
                             busy: Bool, busyProgress: Double? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if busy {
                if let p = busyProgress {
                    ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Image(systemName: icon)
            }
        }
        .help(tip)
        .disabled(busy)
    }

    private func runVLM() {
        vlmRunning = true
        runPython(
            script: "tools/orientation_worker.py",
            args: ["--id-only"],
            tag: "vlm",
            onDone: { vlmRunning = false }
        )
    }

    private func runColnect() {
        colnectRunning = true
        runPython(
            script: "tools/colnect_lookup.py",
            args: [],
            tag: "colnect",
            onDone: { colnectRunning = false }
        )
    }

    /// Runs a Python script with inherited env (so .env.local values loaded
    /// by run.sh — HF_TOKEN, COLNECT_API_KEY — are available).
    private func runPython(script: String, args: [String], tag: String,
                            onDone: @escaping () -> Void) {
        Task.detached {
            let python = Paths.projectRoot.appendingPathComponent(".venv/bin/python").path
            let scriptPath = Paths.projectRoot.appendingPathComponent(script).path
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = [scriptPath] + args
            proc.currentDirectoryURL = Paths.projectRoot
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            print("[\(tag)] \(out.suffix(1000))")
            await MainActor.run { onDone() }
        }
    }
}
