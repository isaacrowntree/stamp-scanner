import Foundation
import Combine

@MainActor
final class WorkerLauncher: ObservableObject {
    enum Health { case starting, healthy, stale, dead }
    @Published private(set) var health: Health = .dead
    @Published private(set) var lastError: String?

    private var process: Process?
    private var heartbeatTimer: Timer?
    private var restartCount = 0
    private var lastLaunch: Date = .distantPast

    func start() {
        guard process == nil else { return }
        Paths.ensureDirs()
        guard FileManager.default.fileExists(atPath: Paths.pythonBin.path) else {
            lastError = "Python venv not found at \(Paths.pythonBin.path). Run ./run.sh to bootstrap."
            health = .dead
            return
        }
        guard FileManager.default.fileExists(atPath: Paths.samModel.path) else {
            lastError = "sam3.pt missing. Download via ./run.sh (requires HuggingFace approval + HF_TOKEN)."
            health = .dead
            return
        }

        // If a worker from a previous session is still alive, don't spawn a
        // second one — they'd race the inbox. Check the PID file; if the
        // process exists, just watch its heartbeat instead.
        if let pidStr = try? String(contentsOf: Paths.pidFile),
           let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            lastError = "existing worker pid \(pid), attaching to heartbeat"
            health = .starting
            lastLaunch = Date()
            startHeartbeatMonitor()
            return
        }

        let p = Process()
        p.executableURL = Paths.pythonBin
        p.arguments = [Paths.workerScript.path, "--daemon"]
        p.currentDirectoryURL = Paths.projectRoot
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.didTerminate(proc) }
        }
        do {
            health = .starting
            lastError = nil
            lastLaunch = Date()
            try p.run()
            process = p
            startHeartbeatMonitor()
        } catch {
            lastError = "launch failed: \(error.localizedDescription)"
            health = .dead
        }
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        process?.terminate()
        process = nil
        health = .dead
    }

    private func didTerminate(_ proc: Process) {
        process = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        let exitedCleanly = proc.terminationReason == .exit && proc.terminationStatus == 0
        if exitedCleanly {
            health = .dead
            return
        }
        // Exponential backoff, capped at 30s; surface banner after 3 failures.
        restartCount += 1
        let delay = min(30.0, pow(2.0, Double(restartCount)))
        lastError = "worker died, restarting in \(Int(delay))s (attempt \(restartCount))"
        health = .dead
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if self.restartCount < 6 { self.start() }
        }
    }

    private func startHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHeartbeat() }
        }
    }

    private func checkHeartbeat() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.heartbeat.path)
        guard let mtime = attrs?[.modificationDate] as? Date else {
            // Starting up — give it ~20s before flagging stale.
            if Date().timeIntervalSince(lastLaunch) > 20 {
                health = .stale
            }
            return
        }
        let age = Date().timeIntervalSince(mtime)
        if age < 6 {
            if health != .healthy { restartCount = 0 }
            health = .healthy
        } else if age < 20 {
            health = .stale
        } else {
            health = .dead
            process?.terminate()
        }
    }
}
