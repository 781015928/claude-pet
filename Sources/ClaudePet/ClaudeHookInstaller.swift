import AppKit
import Foundation

/// 在 ~/.claude/settings.json 注入 / 撤销桌宠的 hook。
/// 转发脚本写到 ~/Library/Application Support/ClaudePet/claude-pet-hook，
/// settings.json 的 hook command 引用这个绝对路径。
enum ClaudeHookInstaller {
    /// 我们要 wire 的 hook 事件列表 —— 跟 PetStateMachine.applyEvent 处理的对应。
    static let events: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "Notification",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "PreCompact"
    ]

    /// hook 转发脚本写入位置。
    /// 故意避开含空格的 ~/Library/Application Support/ —— Claude 把 command 字段交给 shell
    /// 解析时，路径里的空格会把命令拆碎（zsh: no such file or directory: ~/Library/Application）。
    static var hookScriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-pet")
            .appendingPathComponent("claude-pet-hook")
    }

    /// Claude Code 用户级配置文件。
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    /// 当前 settings.json 是否已经注入了我们的 hook。
    static func isInstalled() -> Bool {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = json["hooks"] as? [String: Any]
        else { return false }
        for event in events {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            if entries.contains(where: containsOurHook) {
                return true
            }
        }
        return false
    }

    /// 写脚本 + 注入 settings.json。失败时抛错。
    static func install() throws {
        try writeHookScript()
        // hookScriptURL.path 走 ~/.claude-pet/，无空格，不需要引号包裹
        // —— 同时让用户能直接复制 command 到 shell 测试
        try mutateSettings { hooks in
            for event in events {
                var entries = hooks[event] as? [[String: Any]] ?? []
                entries.removeAll(where: containsOurHook)
                entries.append([
                    "hooks": [[
                        "type": "command",
                        "command": "\(hookScriptURL.path) \(event)"
                    ] as [String: Any]]
                ])
                hooks[event] = entries
            }
            return hooks
        }
    }

    /// 从 settings.json 移除我们注入的所有 hook 条目（不删脚本本身）。
    static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try mutateSettings { hooks in
            for event in events {
                guard var entries = hooks[event] as? [[String: Any]] else { continue }
                entries.removeAll(where: containsOurHook)
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
            return hooks
        }
    }

    // MARK: - Internals

    /// 用 hookScriptURL 路径作为 marker 识别"我们的"hook 条目。
    private static func containsOurHook(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { item in
            (item["command"] as? String)?.contains("claude-pet-hook") == true
        }
    }

    /// 读 settings.json → 让闭包改 .hooks → 写回（pretty-printed）。
    private static func mutateSettings(_ transform: (inout [String: Any]) -> [String: Any]) throws {
        let url = settingsURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var json: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if data.isEmpty {
                json = [:]
            } else {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "ClaudeHookInstaller", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "settings.json 不是合法 JSON 对象"])
                }
                json = parsed
            }
        } else {
            json = [:]
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        hooks = transform(&hooks)
        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        let pretty = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try pretty.write(to: url, options: [.atomic])
    }

    /// 写转发脚本到 ~/.claude-pet/，并赋 +x。
    /// 行为：先尝试 POST 到 127.0.0.1:54321；失败且 ~/.claude-pet/.autostart 存在时
    /// 用 `open -ga ClaudePet` 拉起 app，retry 5 次（每次间隔 0.4s）。
    private static func writeHookScript() throws {
        let url = hookScriptURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let body = """
        #!/usr/bin/env bash
        # ClaudePet hook forwarder —— 由桌宠 app 自动生成。永不阻塞 Claude。
        set +e
        EVENT="${1:-Unknown}"
        PAYLOAD="$(cat)"
        [ -z "$PAYLOAD" ] && PAYLOAD="{}"
        if ! printf '%s' "$PAYLOAD" | python3 -c 'import sys,json; json.load(sys.stdin)' >/dev/null 2>&1; then
          PAYLOAD="{}"
        fi
        BODY=$(printf '{"event":"%s","data":%s}' "$EVENT" "$PAYLOAD")

        post() {
          curl -fsS -X POST "http://127.0.0.1:54321/event" \\
            -H "Content-Type: application/json" \\
            -d "$BODY" \\
            --max-time 0.3 \\
            >/dev/null 2>&1
        }

        # 1) app 在跑 → 直接发
        if post; then exit 0; fi

        # 2) app 没跑 + autostart 启用 → 拉起来再发
        if [ -f "$HOME/.claude-pet/.autostart" ]; then
          open -ga ClaudePet >/dev/null 2>&1
          for _ in 1 2 3 4 5; do
            sleep 0.4
            if post; then exit 0; fi
          done
        fi
        exit 0
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755 as Int16)],
            ofItemAtPath: url.path
        )
    }
}
