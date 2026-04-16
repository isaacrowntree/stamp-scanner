import Foundation
import Combine

/// Watches the SQLite WAL file for external writes (Python worker edits)
/// and publishes a monotonically-increasing tick. Views thread this tick
/// into their `@Query` request so GRDBQuery re-fetches when the underlying
/// file changes — GRDB's internal ValueObservation doesn't fire on writes
/// made by other processes, so we need this external trigger.
@MainActor
final class DatabaseWatcher: ObservableObject {
    @Published private(set) var tick: Int = 0

    private var walSource: DispatchSourceFileSystemObject?
    private var walFD: Int32 = -1
    private var shmSource: DispatchSourceFileSystemObject?
    private var shmFD: Int32 = -1
    private var pollTimer: Timer?

    func start() {
        // WAL file is where GRDB writes land first in WAL journal mode;
        // Python also writes there. Observing it catches every commit.
        watch(suffix: "-wal", into: &walSource, fd: &walFD)
        watch(suffix: "-shm", into: &shmSource, fd: &shmFD)

        // Fallback: poll every 3s in case the WAL is rotated out from
        // under the file descriptor we're watching (SQLite does this on
        // checkpoint). Cheap — just stat + bump tick if mtime changed.
        var lastMTime: Date = .distantPast
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            let base = Paths.sqliteFile
            let paths = [base, base.appendingPathExtension("wal")]
            let newest = paths
                .compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
                .compactMap { $0[.modificationDate] as? Date }
                .max() ?? .distantPast
            if newest > lastMTime {
                lastMTime = newest
                Task { @MainActor in self?.tick &+= 1 }
            }
        }
    }

    func stop() {
        walSource?.cancel(); walSource = nil
        shmSource?.cancel(); shmSource = nil
        pollTimer?.invalidate(); pollTimer = nil
    }

    private func watch(suffix: String,
                        into source: inout DispatchSourceFileSystemObject?,
                        fd: inout Int32) {
        let path = Paths.sqliteFile.path + suffix
        // Try to open the file — if it doesn't exist yet (fresh DB) bail;
        // the poll timer picks it up on next tick.
        let opened = open(path, O_EVTONLY)
        guard opened >= 0 else { return }
        fd = opened
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: opened,
            eventMask: [.write, .extend, .attrib, .link, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick &+= 1 }
        }
        let capturedFD = opened
        src.setCancelHandler { close(capturedFD) }
        src.resume()
        source = src
    }
}
