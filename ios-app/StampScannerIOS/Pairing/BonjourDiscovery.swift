import Foundation
import Network
import Combine

/// Browses `_stampscanner._tcp.local` to find Macs offering the ingest
/// service. Resolves each hit to a host+port so the pairing UI can show a
/// pickable list.
@MainActor
final class BonjourDiscovery: ObservableObject {
    struct DiscoveredMac: Identifiable, Hashable {
        let id: String           // endpoint description, used for dedup
        let name: String         // service name (the Mac's hostname)
        let endpoint: NWEndpoint
    }

    @Published private(set) var results: [DiscoveredMac] = []

    private var browser: NWBrowser?

    func start() {
        stop()
        let desc = NWBrowser.Descriptor.bonjour(type: "_stampscanner._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: desc, using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.results = results.compactMap { r in
                    switch r.endpoint {
                    case .service(let name, _, _, _):
                        return DiscoveredMac(
                            id: "\(r.endpoint)",
                            name: name,
                            endpoint: r.endpoint)
                    default:
                        return nil
                    }
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        results = []
    }
}
