import AppKit
import Foundation

/// 桌宠触发的副作用动作（不属于动画状态）。
enum PetActions {
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
