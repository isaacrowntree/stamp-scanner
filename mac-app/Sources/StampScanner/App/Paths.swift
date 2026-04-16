import Foundation

enum Paths {
    /// Project root — repo directory that contains .run/, tools/, sam3.pt.
    /// For a packaged app we'd look relative to the executable; during
    /// development the app is launched from the repo via ./run.sh so CWD
    /// is the right anchor.
    static let projectRoot: URL = {
        if let env = ProcessInfo.processInfo.environment["STAMP_PROJECT_ROOT"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    static var runDir: URL     { projectRoot.appendingPathComponent(".run") }
    static var inbox: URL      { runDir.appendingPathComponent("sam_inbox") }
    static var outbox: URL     { runDir.appendingPathComponent("sam_outbox") }
    static var workerLog: URL  { runDir.appendingPathComponent("sam_worker.log") }
    static var pidFile: URL    { runDir.appendingPathComponent("sam_worker.pid") }
    static var heartbeat: URL  { runDir.appendingPathComponent("sam_worker.heartbeat") }
    static var samModel: URL   { projectRoot.appendingPathComponent("sam3.pt") }
    static var pythonBin: URL  { projectRoot.appendingPathComponent(".venv/bin/python") }
    static var workerScript: URL { projectRoot.appendingPathComponent("tools/sam_worker.py") }

    /// Persistent storage for saved stamps: copied out of .run/sam_outbox/
    /// so the worker can safely recycle its outbox.
    static var appSupport: URL = {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("StampScanner", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }()

    static var capturesDir: URL { appSupport.appendingPathComponent("captures") }
    static var sourcesDir: URL { capturesDir.appendingPathComponent("_sources") }
    static var swiftDataStore: URL { appSupport.appendingPathComponent("StampScanner.store") }

    static func ensureDirs() {
        for d in [runDir, inbox, outbox, capturesDir, sourcesDir] {
            try? FileManager.default.createDirectory(
                at: d, withIntermediateDirectories: true)
        }
    }
}
