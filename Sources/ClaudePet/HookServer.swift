import Foundation
import Network

/// 极简 HTTP server —— 只接 POST /event，body 是 {"event":..., "data":...}。
/// 设计目标：Claude hook 触发时，curl 一次就走，不阻塞 CLI。
final class HookServer {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let onEvent: (HookEvent) -> Void
    private let queue = DispatchQueue(label: "ClaudePet.HookServer")

    init(port: UInt16, onEvent: @escaping (HookEvent) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.onEvent = onEvent
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑回环
        if let opts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            opts.version = .v4
        }

        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, accumulated: Data())
    }

    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, error in
            guard let self = self else { conn.cancel(); return }
            var buf = accumulated
            if let data = data { buf.append(data) }

            if let event = self.tryParse(buf) {
                self.onEvent(event)
                self.respond(conn, status: 204)
                return
            }
            if isDone || error != nil {
                self.respond(conn, status: 400)
                return
            }
            // 继续读
            self.receive(conn, accumulated: buf)
        }
    }

    private func respond(_ conn: NWConnection, status: Int) {
        let phrase: String = (status == 204) ? "No Content" : "Bad Request"
        let s = "HTTP/1.1 \(status) \(phrase)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: s.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// 解析一个完整的 HTTP 请求 —— 头 + body。
    private func tryParse(_ data: Data) -> HookEvent? {
        // 找 \r\n\r\n
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<sep.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        // 解析 Content-Length
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
        }

        let bodyStart = sep.upperBound
        let available = data.count - bodyStart
        guard available >= contentLength else { return nil }

        let bodyData = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            // body 不是 JSON 也接受 —— 走 query / 空事件
            return nil
        }
        let name = (json["event"] as? String) ?? "Unknown"
        let payload = (json["data"] as? [String: Any]) ?? [:]
        return HookEvent(name: name, data: payload)
    }
}
