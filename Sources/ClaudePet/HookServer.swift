import Foundation
import Network

/// 极简 HTTP server —— 现在监听 0.0.0.0，路由两个 endpoint：
///   POST /event   : 接 Claude hook 事件
///   GET  /install : 返回远程机器一键安装脚本
///
/// 安全策略：
/// - loopback (127.0.0.1 / ::1) 连接：无需 token，行为跟以前一样
/// - 非 loopback 连接：必须 lanEnabled=true 且 header `X-ClaudePet-Token`
///   匹配 token，否则 401。这样默认状态下端口虽然 bind 了 0.0.0.0，对外部
///   仍然是关闭的。
final class HookServer {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let onEvent: (HookEvent) -> Void
    private let queue = DispatchQueue(label: "ClaudePet.HookServer")

    /// 由 AppDelegate 在每次需要时回调拿最新值 —— 避免 settings 变更后还要
    /// 重启 server。
    var lanEnabledProvider: () -> Bool = { false }
    var tokenProvider: () -> String = { "" }

    init(port: UInt16, onEvent: @escaping (HookEvent) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.onEvent = onEvent
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
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

    /// 连接进来 → 检查远端地址判断是否 loopback → 读 HTTP 请求 → 路由分发。
    private func handle(_ conn: NWConnection) {
        let isLoopback = endpointIsLoopback(conn.endpoint)
        conn.start(queue: queue)
        receive(conn, accumulated: Data(), isLoopback: isLoopback)
    }

    private func receive(_ conn: NWConnection, accumulated: Data, isLoopback: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isDone, error in
            guard let self = self else { conn.cancel(); return }
            var buf = accumulated
            if let data = data { buf.append(data) }

            if let req = self.tryParseRequest(buf) {
                self.route(conn, request: req, isLoopback: isLoopback)
                return
            }
            if isDone || error != nil {
                self.respond(conn, status: 400, body: nil)
                return
            }
            self.receive(conn, accumulated: buf, isLoopback: isLoopback)
        }
    }

    // MARK: - Routing

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]  // 全 lowercase key
        let body: Data
    }

    private func route(_ conn: NWConnection, request req: HTTPRequest, isLoopback: Bool) {
        // 非 loopback 必须：开启 lan + 带匹配 token
        if !isLoopback {
            guard lanEnabledProvider() else {
                respond(conn, status: 403, body: "LAN sync disabled\n")
                return
            }
            let want = tokenProvider()
            let got = req.headers["x-claudepet-token"] ?? ""
            guard !want.isEmpty, got == want else {
                respond(conn, status: 401, body: "Bad token\n")
                return
            }
        }

        switch (req.method, req.path) {
        case ("POST", "/event"):
            handleEvent(conn, body: req.body)
        case ("GET", "/install"):
            handleInstall(conn)
        default:
            respond(conn, status: 404, body: nil)
        }
    }

    private func handleEvent(_ conn: NWConnection, body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(conn, status: 400, body: "Bad JSON\n")
            return
        }
        let name = (json["event"] as? String) ?? "Unknown"
        let payload = (json["data"] as? [String: Any]) ?? [:]
        onEvent(HookEvent(name: name, data: payload))
        respond(conn, status: 204, body: nil)
    }

    private func handleInstall(_ conn: NWConnection) {
        let script = RemoteHookScript.makeInstallScript(
            host: PrimaryLANAddress.current() ?? "127.0.0.1",
            port: Int(port.rawValue),
            token: tokenProvider()
        )
        respond(conn, status: 200, body: script,
                contentType: "text/x-shellscript; charset=utf-8")
    }

    // MARK: - HTTP helpers

    private func respond(_ conn: NWConnection,
                         status: Int,
                         body: String?,
                         contentType: String = "text/plain; charset=utf-8") {
        let bodyData = body?.data(using: .utf8) ?? Data()
        let phrase = Self.statusPhrase(status)
        var head = "HTTP/1.1 \(status) \(phrase)\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = head.data(using: .utf8) ?? Data()
        data.append(bodyData)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func statusPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default:  return "Status"
        }
    }

    /// 解析一个完整的 HTTP 请求（request-line + headers + body）。
    private func tryParseRequest(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<sep.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines.dropFirst() {
            let split = line.split(separator: ":", maxSplits: 1)
            guard split.count == 2 else { continue }
            let key = split[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = split[1].trimmingCharacters(in: .whitespaces)
            headers[key] = value
            if key == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }

        let bodyStart = sep.upperBound
        let available = data.count - bodyStart
        guard available >= contentLength else { return nil }
        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Loopback 判定

    /// 判断 NWEndpoint 是否回环地址。NWConnection 的 endpoint 在客户端发起
    /// 时通常是 .hostPort(IPv4/v6, port)；server 端拿到的是对端，我们看它的
    /// host 部分是不是 127.0.0.1 / ::1。
    private func endpointIsLoopback(_ ep: NWEndpoint) -> Bool {
        switch ep {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return addr.isLoopback
            case .ipv6(let addr):
                return addr.isLoopback
            case .name(let name, _):
                return name == "localhost"
            @unknown default:
                return false
            }
        default:
            return false
        }
    }
}
