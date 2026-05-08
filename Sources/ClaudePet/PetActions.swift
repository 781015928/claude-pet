import AppKit
import Foundation

/// 桌宠触发的副作用动作（不属于动画状态）。
enum PetActions {
    /// 跳回某个 Claude session：写一个临时 .command 脚本，用 NSWorkspace 让用户的
    /// 默认终端打开它，自动 cd 到 cwd 后跑 `claude --resume <id> /desktop`。
    ///
    /// 为什么不能用后台 NSTask（即使 -l -i shell + 重定向 stdio）：claude CLI
    /// 启动时检查 isatty(stdin)/isatty(stdout) 决定运行模式，没有 TTY 时会
    /// hang 或退化到错误的模式，slash command `/desktop` 不会被处理。必须给它
    /// 一个真实终端。
    ///
    /// `/desktop` 把 session 推到 Claude Desktop 后 claude CLI 退出；如果你不想
    /// 看 Terminal 窗口残留，去 Terminal → 设置 → 描述文件 → Shell → "Shell
    /// 结束时" 选 "如果 shell 干净退出则关闭"，那以后 resume 后窗口会自动关。
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

        // 顺手把 Claude Desktop 拉到前台 —— /desktop 会把 session 推过去
        launchClaudeDesktop()
    }

    /// 用户默认终端 —— 默认 Terminal.app；可通过 CLAUDE_PET_TERMINAL 覆盖
    /// （比如 /Applications/iTerm.app 或 /Applications/Ghostty.app）。
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
