import AppKit
import Foundation

/// 桌宠触发的副作用动作（不属于动画状态）。
enum PetActions {
    /// 跳回某个 Claude session：用临时 .command 脚本拉起用户默认终端，
    /// 自动 cd 进 cwd 然后 `claude --resume <id> /desktop`。
    /// 比 osascript 控制 Terminal 更通用 —— 用户用 iTerm / Ghostty 等都能 work，
    /// 也不需要 Automation 权限。
    static func resumeClaudeSession(id: String, cwd: String?) {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-resume-\(UUID().uuidString).command")
        var body = "#!/usr/bin/env bash\nset -e\n"
        if let cwd = cwd, !cwd.isEmpty {
            body += "cd \(shellQuote(cwd))\n"
        }
        body += "claude --resume \(shellQuote(id)) /desktop\n"

        do {
            try body.write(to: tmpURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755 as Int16)],
                ofItemAtPath: tmpURL.path
            )
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(
                [tmpURL],
                withApplicationAt: defaultTerminalAppURL(),
                configuration: config
            ) { _, error in
                if let error = error {
                    NSLog("[ClaudePet] open .command failed: \(error)")
                }
            }
        } catch {
            NSLog("[ClaudePet] resume failed: \(error)")
        }
    }

    /// 找用户默认终端：默认 Terminal.app；可通过 CLAUDE_PET_TERMINAL 环境变量覆盖。
    private static func defaultTerminalAppURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_PET_TERMINAL"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    /// 简单 POSIX 单引号转义。
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 唤起 Claude Desktop（已运行则带到前台，未运行则启动）。
    static func launchClaudeDesktop() {
        let ws = NSWorkspace.shared
        let bundleIDs = [
            "com.anthropic.claudefordesktop",
            "com.anthropic.claude"
        ]
        for bid in bundleIDs {
            if let url = ws.urlForApplication(withBundleIdentifier: bid) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                ws.openApplication(at: url, configuration: config) { _, error in
                    if let error = error {
                        NSLog("[ClaudePet] open Claude failed: \(error)")
                    }
                }
                return
            }
        }
        // 兜底：用 open -a 按显示名启动
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Claude"]
        do {
            try task.run()
        } catch {
            NSLog("[ClaudePet] /usr/bin/open Claude failed: \(error)")
        }
    }
}
