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
        // We never intentionally stop the worker during normal operation
        // — even a clean exit means something went wrong (SIGTERM from us
        // due to stale heartbeat, OS kill, crash, etc). Always restart
        // with a short backoff.
        restartCount += 1
        let delay = min(15.0, pow(1.5, Double(restartCount)))
        lastError = "worker exited (code \(proc.terminationStatus)), restarting in \(Int(delay))s (attempt \(restartCount))"
        health = .dead
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if self.restartCount < 20 { self.start() }
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
            // Starting up — give it ~30s before flagging stale. First run
            // needs to load Qwen3-VL or SAM 3 weights which takes a while.
            if Date().timeIntervalSince(lastLaunch) > 30 {
                health = .stale
            }
            return
        }
        let age = Date().timeIntervalSince(mtime)
        // Thresholds are generous: SAM jobs on a backlog can take 30s+
        // total (e.g. 3 back-to-back captures each taking ~10s). The
        // worker now touches heartbeat between every file, but we stay
        // tolerant in case the machine is under load.
        if age < 15 {
            if health != .healthy { restartCount = 0 }
            health = .healthy
        } else if age < 60 {
            health = .stale
        } else {
            health = .dead
            process?.terminate()
        }
    }
}
