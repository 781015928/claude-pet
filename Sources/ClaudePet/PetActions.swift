import AppKit
import Foundation

/// 桌宠触发的副作用动作（不属于动画状态）。
enum PetActions {
    /// 跳回某个 Claude session：直接用 NSTask 在后台跑
    /// `claude --resume <id> /desktop`，**不开任何终端窗口**。
    ///
    /// 设计要点：
    /// - `/desktop` slash command 会把 session 推回 Claude Desktop，claude CLI
    ///   随后自然退出 → 没有 CLI 残留、没有终端窗口要回收。
    /// - 用 login + interactive shell（`-l -i`）以加载用户 PATH（claude 经常装
    ///   在 nvm / homebrew / npm-global，需要 .zshrc / .bash_profile 提供路径）。
    /// - stdin/stdout/stderr 全部丢 /dev/null，不阻塞、不漏字符到我们这边。
    /// - 同时把 Claude Desktop 拉到前台，省得用户切前台。
    static func resumeClaudeSession(id: String, cwd: String?) {
        let task = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        task.launchPath = shell

        var script = ""
        if let cwd = cwd, !cwd.isEmpty {
            script += "cd \(shellQuote(cwd)) && "
        }
        script += "claude --resume \(shellQuote(id)) /desktop"

        task.arguments = ["-l", "-i", "-c", script]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            NSLog("[ClaudePet] resume failed: \(error)")
        }

        // 顺手把 Claude Desktop 拉到前台 —— /desktop 会把 session 推过去
        launchClaudeDesktop()
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
