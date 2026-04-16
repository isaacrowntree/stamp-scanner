import Foundation
import Combine

/// Periodically pings the paired Mac's /health endpoint. Publishes a
/// three-state connection status the UI can surface so the user isn't
/// silently queuing captures into an unreachable Mac.
@MainActor
final class ConnectionMonitor: ObservableObject {
    enum State: Equatable {
        case unknown        // no ping yet / no bond
        case online         // last ping succeeded
        case offline        // last ping failed
    }

    @Published private(set) var state: State = .unknown

    private var task: Task<Void, Never>?
    private let interval: TimeInterval = 8

    func start(bond: PairingStore.Bond?) {
        task?.cancel()
        guard let bond else { state = .unknown; return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ping(bond: bond)
                try? await Task.sleep(nanoseconds: UInt64(8 * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func ping(bond: PairingStore.Bond) async {
        guard let url = URL(string: "http://\(bond.host):\(bond.port)/health") else {
            state = .offline
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                state = .online
            } else {
                state = .offline
            }
        } catch {
            state = .offline
        }
    }
}
