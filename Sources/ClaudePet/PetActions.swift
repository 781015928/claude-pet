import AppKit
import Foundation

/// 桌宠触发的副作用动作（不属于动画状态）。
enum PetActions {
    /// 跳回某个 Claude session，**不开任何终端窗口**。
    ///
    /// 难点：claude CLI 用 isatty(stdin/stdout) 决定运行模式 —— 没有 TTY 时它
    /// 不会执行 `/desktop` slash command，所以单纯的 NSTask + nullDevice 不行。
    ///
    /// 解法：用 `/usr/bin/script -q /dev/null …`（macOS BSD 自带）给子命令套一层
    /// PTY。`script` 内部 forkpty + exec，被启动的命令看到 `isatty(0/1) == 1`，
    /// 表现得跟在 Terminal 里跑一模一样。父进程（我们的 NSTask）的 stdio 仍是
    /// /dev/null，没有任何窗口被打开，子进程跑完 script 自动退出，零残留。
    ///
    /// `/desktop` 执行后 claude CLI 自然退出 → script 退出 → NSTask 进程结束。
    static func resumeClaudeSession(id: String, cwd: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // 用户 shell 命令：cd 进 cwd（claude --resume 按当前目录的 project hash
        // 找 session，路径错了会 No conversation found）然后跑 claude /desktop
        var inner = ""
        if let cwd = cwd, !cwd.isEmpty {
            inner += "cd \(shellQuote(cwd)) && "
        }
        inner += "claude --resume \(shellQuote(id)) /desktop"

        let task = Process()
        task.launchPath = "/usr/bin/script"
        // -q 静默；/dev/null 丢弃 typescript；-l -i 让 shell 加载 PATH (.zshrc /
        // .bash_profile)，nvm / homebrew / npm-global 装的 claude 都能找到
        task.arguments = ["-q", "/dev/null", shell, "-l", "-i", "-c", inner]
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
