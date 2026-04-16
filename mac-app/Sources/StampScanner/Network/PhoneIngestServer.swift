import Foundation
import Network
import Combine

/// Thin HTTP/1.1 listener that accepts captures from the paired iPhone
/// and drops them into .run/sam_inbox/ for the Python worker. All ingest
/// logic (SAM → dedup → library insert) happens in Python.
///
/// Endpoints:
///   POST /submit     multipart/form-data with "photo" part (HEIC/JPEG)
///   POST /pair       {"code":"123456","peerName":"…"} → {"secret":"…"}
///   GET  /health     {"ok":true,"paired":true}
@MainActor
final class PhoneIngestServer: ObservableObject {
    enum Mode: Equatable { case off, loopback, lan }

    @Published private(set) var mode: Mode = .off
    @Published private(set) var lastSeen: Date?
    @Published private(set) var jobCount: Int = 0

    private var listener: NWListener?
    static let port: NWEndpoint.Port = 47000

    func start(mode: Mode, advertiseAs bonjourName: String? = nil) {
        stop()
        guard mode != .off else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if mode == .loopback {
            params.requiredInterfaceType = .loopback
        }
        params.includePeerToPeer = (mode == .lan)
        do {
            let l = try NWListener(using: params, on: Self.port)
            if mode == .lan {
                let name = bonjourName ?? Host.current().localizedName ?? "Mac"
                l.service = NWListener.Service(name: name, type: "_stampscanner._tcp")
                print("[ingest] advertising _stampscanner._tcp as '\(name)' on port \(Self.port)")
            }
            l.stateUpdateHandler = { state in
                print("[ingest] listener state: \(state)")
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(conn) }
            }
            l.start(queue: .main)
            listener = l
            self.mode = mode
        } catch {
            print("[ingest] start failed: \(error)")
            self.mode = .off
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        mode = .off
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let err { print("recv err: \(err)"); conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let (headers, body, _) = Self.splitRequest(buf) {
                let contentLength = Int(headers.header("Content-Length") ?? "0") ?? 0
                if body.count >= contentLength {
                    let bodySlice = body.prefix(contentLength)
                    Task { @MainActor in
                        self.route(headers: headers, body: Data(bodySlice), on: conn)
                    }
                    return
                }
            }
            if isComplete { conn.cancel(); return }
            Task { @MainActor in self.receiveRequest(conn, buffer: buf) }
        }
    }

    private func route(headers: Headers, body: Data, on conn: NWConnection) {
        lastSeen = Date()
        let path = headers.path
        let method = headers.method

        if method == "GET", path == "/health" {
            respond(conn, status: 200, json: [
                "ok": true,
                "paired": PairingStore.currentSecret != nil,
                "peer": PairingStore.peerName ?? "",
            ])
            return
        }
        if method == "POST", path == "/pair" {
            handlePair(body: body, on: conn)
            return
        }

        guard let secret = PairingStore.currentSecret,
              let got = headers.header("Authorization"),
              got == "Bearer \(secret)" else {
            respond(conn, status: 401, json: ["error": "unauthorized"])
            return
        }

        switch (method, path) {
        case ("POST", "/submit"):
            handleSubmit(headers: headers, body: body, on: conn)
        default:
            respond(conn, status: 404, json: ["error": "not found"])
        }
    }

    private func handlePair(body: Data, on conn: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = json["code"] as? String else {
            respond(conn, status: 400, json: ["error": "expected {code,peerName}"]); return
        }
        guard let secret = PairingStore.currentSecret else {
            respond(conn, status: 403, json: ["error": "pairing not open on Mac"]); return
        }
        let expected = PairingStore.pairingCode(for: secret)
        guard code == expected else {
            respond(conn, status: 403, json: ["error": "wrong code"]); return
        }
        let peerName = (json["peerName"] as? String) ?? "iPhone"
        PairingStore.setPeerName(peerName)
        respond(conn, status: 200, json: [
            "secret": secret,
            "peer": Host.current().localizedName ?? "Mac",
        ])
    }

    private func handleSubmit(headers: Headers, body: Data, on conn: NWConnection) {
        guard let contentType = headers.header("Content-Type"),
              let boundary = Self.multipartBoundary(from: contentType) else {
            respond(conn, status: 400, json: ["error": "expected multipart/form-data"])
            return
        }
        guard let photo = Self.extractPart(named: "photo", body: body, boundary: boundary) else {
            respond(conn, status: 400, json: ["error": "missing photo part"])
            return
        }

        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let rand = String(format: "%04x", UInt32.random(in: 0...0xFFFF))
        let jobId = "\(ms)\(rand)"
        let ext = Self.detectExtension(data: photo.data)
        let tmp = Paths.inbox.appendingPathComponent("\(jobId).\(ext).tmp")
        let final = Paths.inbox.appendingPathComponent("\(jobId).\(ext)")
        do {
            Paths.ensureDirs()
            try photo.data.write(to: tmp, options: .atomic)
            try FileManager.default.moveItem(at: tmp, to: final)
            jobCount += 1
            respond(conn, status: 200, json: ["jobId": jobId, "accepted": true])
        } catch {
            respond(conn, status: 500, json: ["error": "write failed: \(error.localizedDescription)"])
        }
    }

    // MARK: - Response helpers

    private func respond(_ conn: NWConnection, status: Int, json: [String: Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var buf = Data(head.utf8)
        buf.append(payload)
        conn.send(content: buf, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }

    // MARK: - Request parsing

    private struct Headers {
        let method: String
        let path: String
        let headers: [(String, String)]
        func header(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }
    }

    private static func splitRequest(_ buf: Data) -> (Headers, Data, Int)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buf.range(of: sep) else { return nil }
        let headerData = buf.subdata(in: 0..<range.lowerBound)
        let body = buf.subdata(in: range.upperBound..<buf.count)
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers.append((k, v))
            }
        }
        return (Headers(method: method, path: path, headers: headers), body, range.upperBound)
    }

    private static func multipartBoundary(from contentType: String) -> String? {
        let parts = contentType.split(separator: ";")
        for p in parts {
            let kv = p.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "boundary" {
                return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
        }
        return nil
    }

    private struct Part { let name: String; let filename: String?; let data: Data }

    private static func extractPart(named target: String, body: Data, boundary: String) -> Part? {
        let delim = Data("--\(boundary)".utf8)
        var idx = 0
        var parts: [Data] = []
        while idx < body.count {
            guard let r = body.range(of: delim, in: idx..<body.count) else { break }
            if !parts.isEmpty || r.lowerBound > idx {
                parts.append(body.subdata(in: idx..<r.lowerBound))
            }
            idx = r.upperBound
            if idx + 2 <= body.count {
                let peek = body.subdata(in: idx..<min(idx + 2, body.count))
                if peek == Data("--".utf8) { break }
                if peek == Data("\r\n".utf8) { idx += 2 }
            }
        }
        for p in parts {
            let sep = Data("\r\n\r\n".utf8)
            guard let hr = p.range(of: sep) else { continue }
            let hdrData = p.subdata(in: 0..<hr.lowerBound)
            var content = p.subdata(in: hr.upperBound..<p.count)
            if content.count >= 2, content.suffix(2) == Data("\r\n".utf8) {
                content = content.subdata(in: 0..<(content.count - 2))
            }
            guard let header = String(data: hdrData, encoding: .utf8) else { continue }
            guard header.lowercased().contains("content-disposition:") else { continue }
            guard let nameRange = header.range(of: #"name="([^"]+)""#, options: .regularExpression),
                  let nameStart = header.range(of: "\"", range: nameRange),
                  let nameEnd = header.range(of: "\"", range: nameStart.upperBound..<nameRange.upperBound) else { continue }
            let name = String(header[nameStart.upperBound..<nameEnd.lowerBound])
            guard name == target else { continue }
            var filename: String?
            if let fr = header.range(of: #"filename="([^"]+)""#, options: .regularExpression),
               let fs = header.range(of: "\"", range: fr),
               let fe = header.range(of: "\"", range: fs.upperBound..<fr.upperBound) {
                filename = String(header[fs.upperBound..<fe.lowerBound])
            }
            return Part(name: name, filename: filename, data: content)
        }
        return nil
    }

    private static func detectExtension(data: Data) -> String {
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 { return "jpg" }
        if data.count >= 12 {
            let ftype = data.subdata(in: 4..<12)
            if let s = String(data: ftype, encoding: .ascii),
               s.hasPrefix("ftyp") && (s.contains("heic") || s.contains("heix") || s.contains("mif1")) {
                return "heic"
            }
        }
        if data.count >= 4, data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        return "jpg"
    }
}
