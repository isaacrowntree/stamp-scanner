import Foundation
import Network
import Combine
import UIKit

/// Disk-backed outbox for HEIC uploads. Any capture that can't be sent
/// immediately is persisted to the app's Caches dir; we flush on
/// NWPathMonitor .satisfied.
@MainActor
final class UploadQueue: ObservableObject {
    @Published private(set) var uploadedCount: Int = 0
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var lastError: String?

    /// Bond is settable so the queue can live higher in the view tree and
    /// pick up the pairing store once the user is through PairingView.
    var bond: PairingStore.Bond? {
        didSet { if bond != nil { flush() } }
    }

    private let outboxDir: URL
    private let monitor = NWPathMonitor()
    private var flushing = false

    init() {
        let caches = try! FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        self.outboxDir = caches.appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        recountPending()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                if path.status == .satisfied { self?.flush() }
            }
        }
        monitor.start(queue: .main)
    }

    func submit(_ heic: Data) {
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).heic"
        let url = outboxDir.appendingPathComponent(String(name))
        do {
            try heic.write(to: url, options: .atomic)
            recountPending()
            flush()
        } catch {
            lastError = "queue write failed: \(error.localizedDescription)"
        }
    }

    private func flush() {
        guard !flushing else { return }
        guard let bond = bond else { return }
        flushing = true
        Task {
            defer { Task { @MainActor in self.flushing = false } }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: outboxDir, includingPropertiesForKeys: nil))
                .map { $0.sorted { $0.path < $1.path } } ?? []
            for file in files {
                do {
                    let data = try Data(contentsOf: file)
                    try await send(data, to: bond)
                    try? FileManager.default.removeItem(at: file)
                    await MainActor.run {
                        self.uploadedCount += 1
                        self.recountPending()
                        self.lastError = nil
                    }
                } catch {
                    await MainActor.run { self.lastError = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func recountPending() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: outboxDir, includingPropertiesForKeys: nil)) ?? []
        pendingCount = files.count
    }

    private func send(_ heic: Data, to bond: PairingStore.Bond) async throws {
        guard let url = URL(string: "http://\(bond.host):\(bond.port)/submit") else {
            throw URLError(.badURL)
        }
        let boundary = "----StampScanner-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bond.secret)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"capture.heic\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/heic\r\n\r\n".data(using: .utf8)!)
        body.append(heic)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
