import SwiftUI

struct LibraryToolbar: ToolbarContent {
    @Binding var filter: LibraryFilter
    @Binding var selection: Set<String>
    @Binding var showInspector: Bool
    @Binding var vlmRunning: Bool
    @Binding var colnectRunning: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TextField("Search", text: $filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 260)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                runVLM()
            } label: {
                if vlmRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Identify", systemImage: "sparkles.rectangle.stack")
                }
            }
            .help("Identify unprocessed stamps via Qwen3-VL")
            .disabled(vlmRunning)

            Button {
                runColnect()
            } label: {
                if colnectRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Colnect", systemImage: "books.vertical")
                }
            }
            .help("Match identified stamps to Colnect catalogue (requires COLNECT_API_KEY)")
            .disabled(colnectRunning)

            Picker("Sort", selection: $filter.sort) {
                ForEach(SortOrder.allCases, id: \.self) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.menu)
            .help("Sort order")

            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: showInspector ? "sidebar.right" : "sidebar.trailing")
            }
            .help("Toggle inspector")
        }
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
