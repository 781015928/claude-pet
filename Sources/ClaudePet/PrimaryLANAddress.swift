import Foundation
import Darwin

/// 获取本机非 loopback 的 IPv4 地址 —— 用于：
/// 1) `/install` 端点返回的远程脚本，把 host 填成内网可达地址
/// 2) 菜单 "局域网同步" 子菜单显示本机 IP 让用户复制
enum PrimaryLANAddress {
    /// 返回最适合让远程机器回连的本机 IPv4。
    /// 优先级：私有段（192.168.x.x / 10.x.x.x / 172.16-31.x.x） > 其他非 loopback
    static func current() -> String? {
        let all = collectIPv4()
        if let priv = all.first(where: isPrivate) { return priv }
        return all.first
    }

    /// 所有 active 非 loopback IPv4，用于菜单展示。
    static func all() -> [String] {
        return collectIPv4()
    }

    static func isPrivate(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]) {
                return (16...31).contains(second)
            }
        }
        return false
    }

    /// 通过 getifaddrs 枚举接口；只挑 AF_INET、IFF_UP、非 IFF_LOOPBACK 的。
    private static func collectIPv4() -> [String] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var addrs: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            guard (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let err = getnameinfo(sa,
                                  socklen_t(sa.pointee.sa_len),
                                  &host, socklen_t(host.count),
                                  nil, 0, NI_NUMERICHOST)
            if err == 0 {
                addrs.append(String(cString: host))
            }
        }
        return addrs
    }
}
