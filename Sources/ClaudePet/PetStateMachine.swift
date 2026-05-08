import Foundation
import Combine

/// 宠物视觉状态。
enum PetState: String {
    case idle           // 空闲：吐舌头、摇尾巴
    case thinking       // 思考：歪头 + 省略号
    case working        // 工作：对着电脑疯狂打字
    case notification   // 求确认：跳起来吠
    case done           // 完成：眼睛追随鼠标 + 吐舌头
    case sleeping       // 长时间空闲
    case running        // 在屏幕底部跑步
    case failed         // 工具调用失败 / 错误（Codex row 5）
}

/// sleeping 的两种变体——状态机进入 sleeping 时随机选一种。
enum SleepVariant: String {
    case curl   // 蜷缩在屏幕右下角睡觉
    case bored  // 原地无聊（半闭眼、叹气）
}

/// 来自 Claude Code hook 的事件。
struct HookEvent {
    let name: String
    let data: [String: Any]
}

final class PetStateMachine: ObservableObject {
    @Published var state: PetState = .idle
    @Published var sleepVariant: SleepVariant = .curl
    @Published var bubble: String = ""

    /// 一次性动画：覆盖当前 state 对应的 sprite 行，播一遍后自动清空。
    /// 不影响 state 本身（hook 仍然可以推进状态机）。
    @Published var oneshot: SpriteAnimation? = nil

    /// 最近一次 hook 事件附带的 session 上下文，用于：
    /// 1) 在气泡里把 session 名（cwd basename）显示出来
    /// 2) 单击桌宠时通过 `claude --resume <id>` 跳回那个会话
    @Published var lastSessionID: String?
    @Published var lastCwd: String?

    /// session 的可读名 = cwd 的最后一段目录名。
    var sessionName: String {
        guard let cwd = lastCwd, !cwd.isEmpty else { return "" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private var resetWork: DispatchWorkItem?
    private var sleepWork: DispatchWorkItem?
    private var oneshotWork: DispatchWorkItem?

    /// 多久没事件后进入 sleeping。
    var sleepDelay: TimeInterval = 300

    init() {
        scheduleSleep()
    }

    func handle(event: HookEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.applyEvent(event)
        }
    }

    /// 触发跑步：duration 期间状态保持 .running，结束后回 .idle。
    /// 窗口移动由 PetWindow 自己监听并执行。
    func startRunning(duration: TimeInterval = 6) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.resetWork?.cancel()
            self.sleepWork?.cancel()
            self.state = .running
            self.bubble = "跑跑跑！"
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.state = .idle
                self.bubble = ""
                self.scheduleSleep()
            }
            self.resetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    private func applyEvent(_ event: HookEvent) {
        // 任何 hook 都更新 session 上下文（每个 event 都含 session_id / cwd）
        if let sid = event.data["session_id"] as? String, !sid.isEmpty {
            lastSessionID = sid
        }
        if let cwd = event.data["cwd"] as? String, !cwd.isEmpty {
            lastCwd = cwd
        }

        switch event.name {
        case "SessionStart":
            let source = (event.data["source"] as? String) ?? "startup"
            let bubble: String
            switch source {
            case "resume":  bubble = "回来啦"
            case "clear":   bubble = "刷新了"
            case "compact": bubble = "整理后回来"
            default:        bubble = "嗨"
            }
            transition(to: .idle, bubble: bubble, autoReset: 3)

        case "UserPromptSubmit":
            // prompt 截前 14 字进气泡（隐私见 README 说明）
            let raw = (event.data["prompt"] as? String) ?? ""
            let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let bubble = prompt.isEmpty ? "想想…" : Self.truncate(prompt, max: 14)
            transition(to: .thinking, bubble: bubble)

        case "PreToolUse":
            let tool = (event.data["tool_name"] as? String) ?? "干活"
            let input = (event.data["tool_input"] as? [String: Any]) ?? [:]
            transition(to: .working, bubble: Self.bubbleForTool(tool, input: input))

        case "PostToolUse":
            transition(to: .working, bubble: "")

        case "PostToolUseFailure":
            // 工具失败 → 流泪 row 5
            let tool = (event.data["tool_name"] as? String) ?? "工具"
            transition(to: .failed, bubble: "✗ \(tool) 失败", autoReset: 6)

        case "PermissionRequest":
            // 比 Notification 更具体 —— 含工具名 + 命令/文件
            let tool = (event.data["tool_name"] as? String) ?? "工具"
            let input = (event.data["tool_input"] as? [String: Any]) ?? [:]
            let detail = Self.detailForPermission(tool: tool, input: input)
            let bubble = detail.isEmpty ? "🛂 \(tool) 等授权" : "🛂 \(detail)"
            transition(to: .notification, bubble: bubble, autoReset: nil)

        case "Notification":
            // 持续显示，直到用户单击 ack（详见 PetView.handleSingleClick）
            transition(to: .notification,
                       bubble: "主人我都干完了，你快来看",
                       autoReset: nil)

        case "Stop":
            transition(to: .done, bubble: "搞定！", autoReset: 6)

        case "SubagentStart":
            let agent = (event.data["agent_type"] as? String) ?? "子代理"
            transition(to: .working, bubble: "🤖 \(agent)")

        case "SubagentStop":
            let agent = (event.data["agent_type"] as? String) ?? ""
            let bubble = agent.isEmpty ? "+1" : "\(agent) 回来了"
            transition(to: .done, bubble: bubble, autoReset: 3)

        case "PreCompact":
            let trigger = (event.data["compaction_trigger"] as? String) ?? "manual"
            let bubble = trigger == "auto" ? "自动整理…" : "整理…"
            transition(to: .working, bubble: bubble, autoReset: 4)

        case "__Run__":
            // 调试钩子：用 curl 触发跑步
            let dur = (event.data["duration"] as? Double) ?? 6
            startRunning(duration: dur)
        case "__Click__":
            // 调试钩子：模拟单击 → 随机 waving / jumping / review
            let pool: [CodexRow] = [.waving, .jumping, .review]
            if let pick = pool.randomElement() {
                playOneshot(SpriteAnimation(pick))
            }
        case "__DoubleClick__":
            // 调试钩子：模拟双击 → 唤起 Claude Desktop
            PetActions.launchClaudeDesktop()
        case "__Failed__":
            // 调试钩子：直接进入 .failed 状态
            transition(to: .failed, bubble: "出错了", autoReset: 6)
        default:
            break
        }
    }

    /// 用户在桌宠上单击 → 确认收到通知，从 .notification 回 idle。
    /// 仅当当前是 .notification 时生效（其他状态调用是 no-op）。
    func acknowledgeNotification() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.state == .notification else { return }
            self.resetWork?.cancel()
            self.state = .idle
            self.bubble = ""
            self.scheduleSleep()
        }
    }

    // MARK: - 工具气泡帮手

    /// 把任意字符串安全截断到 max 字（按 Character，中文也按字数算）
    private static func truncate(_ s: String, max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }

    /// PreToolUse 气泡：按工具类型从 tool_input 抽适合显示的字段。
    private static func bubbleForTool(_ tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            // 显示 LLM 给的 description（人类可读、避免暴露具体命令参数）
            if let desc = (input["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                return "$ " + truncate(desc, max: 18)
            }
            return "Bash"
        case "Edit", "Write":
            if let path = input["file_path"] as? String {
                let name = (path as NSString).lastPathComponent
                return "✎ " + truncate(name, max: 18)
            }
            return tool
        case "Read":
            if let path = input["file_path"] as? String {
                let name = (path as NSString).lastPathComponent
                return "📖 " + truncate(name, max: 18)
            }
            return "Read"
        case "Grep":
            if let p = input["pattern"] as? String {
                return "🔍 " + truncate(p, max: 18)
            }
            return "Grep"
        case "Glob":
            if let p = input["pattern"] as? String {
                return "📁 " + truncate(p, max: 18)
            }
            return "Glob"
        case "WebFetch":
            if let url = input["url"] as? String {
                let host = URL(string: url)?.host ?? truncate(url, max: 18)
                return "🌐 " + host
            }
            return "WebFetch"
        case "Agent":
            if let st = input["subagent_type"] as? String {
                return "🤖 " + st
            }
            return "Agent"
        case "AskUserQuestion":
            return "🙋 等回答"
        default:
            return tool
        }
    }

    /// PermissionRequest 气泡：含工具 + 关键参数。
    private static func detailForPermission(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let cmd = input["command"] as? String {
            return tool + ": " + truncate(cmd, max: 14)
        }
        if let path = input["file_path"] as? String {
            let name = (path as NSString).lastPathComponent
            return tool + " " + truncate(name, max: 14)
        }
        return ""
    }

    /// 播一次性动画，时长 = 该动画 totalDuration（最少 0.5s）。
    /// 高频持续调用同 row 时只续期，不重置 sprite 内部时钟 —— 防闪。
    func playOneshot(_ animation: SpriteAnimation) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.oneshotWork?.cancel()
            // 同 row 不再赋值 oneshot —— 否则 SpriteAnimationView 的 onChange 会
            // 把 startTime 重置成当前，sprite 永远卡在第 0 帧
            if self.oneshot?.row != animation.row {
                self.oneshot = animation
            }
            let lifetime = max(animation.totalDuration, 0.5)
            let work = DispatchWorkItem { [weak self] in
                self?.oneshot = nil
            }
            self.oneshotWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: work)
        }
    }

    private func transition(to newState: PetState, bubble: String, autoReset: TimeInterval? = nil) {
        self.state = newState
        self.bubble = bubble

        resetWork?.cancel()
        if let delay = autoReset {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.state = .idle
                self.bubble = ""
            }
            resetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        scheduleSleep()
    }

    /// 闲置 sleepDelay 秒 → sleeping，并随机选一种变体。
    private func scheduleSleep() {
        sleepWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.state == .idle {
                self.sleepVariant = Bool.random() ? .curl : .bored
                self.state = .sleeping
                self.bubble = self.sleepVariant == .curl ? "Zzz" : "无聊…"
            }
        }
        sleepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + sleepDelay, execute: work)
    }
}
