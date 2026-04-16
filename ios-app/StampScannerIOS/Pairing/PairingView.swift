import SwiftUI
import Network

/// First-run pairing screen: discover Macs via Bonjour, user picks one,
/// enters the 6-digit code shown on that Mac, we exchange it for the
/// actual bearer secret via POST /pair, then we're bonded.
struct PairingView: View {
    @EnvironmentObject var pairing: PairingStore
    @StateObject private var discovery = BonjourDiscovery()

    @State private var selected: BonjourDiscovery.DiscoveredMac?
    @State private var code: String = ""
    @State private var status: String = ""
    @State private var resolving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Nearby Macs") {
                    if discovery.results.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Looking for your Mac…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(discovery.results) { mac in
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(mac.name)
                            Spacer()
                            if selected?.id == mac.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = mac }
                    }
                }
                if selected != nil {
                    Section("Pairing code") {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .onChange(of: code) { _, v in
                                code = String(v.prefix(6).filter(\.isNumber))
                            }
                        Button {
                            pair()
                        } label: {
                            if resolving { ProgressView() } else { Text("Pair") }
                        }
                        .disabled(code.count != 6 || resolving)
                    }
                }
                if !status.isEmpty {
                    Section { Text(status).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Pair with Mac")
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    private func pair() {
        guard let mac = selected else { return }
        resolving = true
        status = "Connecting…"
        Task {
            do {
                let (host, port) = try await resolveEndpoint(mac.endpoint)
                let payload = ["code": code, "peerName": UIDevice.current.name]
                var req = URLRequest(url: URL(string: "http://\(host):\(port)/pair")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard http.statusCode == 200,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let secret = body["secret"] as? String else {
                    let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let err = body?["error"] as? String ?? "HTTP \(http.statusCode)"
                    status = "Pairing failed: \(err)"
                    resolving = false
                    return
                }
                let peer = (body["peer"] as? String) ?? mac.name
                await pairing.save(.init(host: host, port: port, peerName: peer, secret: secret))
                status = "Paired with \(peer)"
                resolving = false
            } catch {
                status = "Error: \(error.localizedDescription)"
                resolving = false
            }
        }
    }

    /// NWEndpoint.service doesn't expose host/port directly — we have to
    /// open a throwaway connection to resolve them. Network.framework's
    /// `currentPath.remoteEndpoint` gives us the resolved address once the
    /// handshake is ready.
    private func resolveEndpoint(_ endpoint: NWEndpoint) async throws -> (String, Int) {
        try await withCheckedThrowingContinuation { cont in
            let conn = NWConnection(to: endpoint, using: .tcp)
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint ?? endpoint {
                        let hostStr: String
                        switch host {
                        case .name(let n, _): hostStr = n
                        case .ipv4(let a): hostStr = "\(a)"
                        case .ipv6(let a): hostStr = "[\(a)]"
                        @unknown default: hostStr = "unknown"
                        }
                        cont.resume(returning: (hostStr, Int(port.rawValue)))
                    } else {
                        cont.resume(throwing: URLError(.cannotFindHost))
                    }
                    conn.cancel()
                } else if case .failed(let e) = state {
                    cont.resume(throwing: e)
                    conn.cancel()
                }
            }
            conn.start(queue: .main)
        }
    }
}
