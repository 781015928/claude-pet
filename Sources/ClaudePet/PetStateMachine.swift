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

/// 待用户 ack 的"完成 / 通知"事件，按 (sessionID, kind) 去重。
/// 多个 session 同时完成时会同时存在多条 —— 单击桌宠按队首先处理。
///
/// 关键：sessionID 和 cwd 在入队时**冻结**，后续别的 hook 不会污染 ——
/// 这是修复"单击跳到错误 session / Claude Desktop 出现 General coding session"
/// 的根因，之前用全局 lastSessionID 会被任何 hook 覆盖。
struct PendingTask: Identifiable, Equatable {
    enum Kind { case done, notification }

    let id: UUID = UUID()
    let sessionID: String
    let cwd: String
    /// 远程机器的 hostname（远程 forwarder 在 payload 里加进来）；本机 hook
    /// 为 nil。在气泡里跟 cwd basename 一起拼，让用户能区分多机器同名项目。
    let hostname: String?
    let kind: Kind
    /// 入队当下要展示的气泡文案（"搞定" / "🛂 Bash: ..." 之类）；后续 hook 不影响它
    let detail: String
    let timestamp: Date

    /// session 可读名：本机 → `dir`；远程 → `host:dir`。
    var sessionName: String {
        let dir = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
        let dirText = dir.isEmpty ? cwd : dir
        if let host = hostname, !host.isEmpty {
            return dirText.isEmpty ? host : "\(host):\(dirText)"
        }
        return dirText
    }

    static func == (lhs: PendingTask, rhs: PendingTask) -> Bool { lhs.id == rhs.id }
}

final class PetStateMachine: ObservableObject {
    @Published var state: PetState = .idle
    @Published var sleepVariant: SleepVariant = .curl
    @Published var bubble: String = ""

    /// 一次性动画：覆盖当前 state 对应的 sprite 行，播一遍后自动清空。
    /// 不影响 state 本身（hook 仍然可以推进状态机）。
    @Published var oneshot: SpriteAnimation? = nil

    /// 待用户 ack 的完成 / 通知队列。FIFO，单击桌宠从队首弹出。
    /// 同 (sessionID, kind) 的二次事件会**更新现有条目**而非入新（避免同一
    /// session 反复 Stop 导致气泡被无限挤）。
    @Published var pendingTasks: [PendingTask] = []

    /// 队首 —— 即当前气泡 / 单击 ack 应该处理的那条。
    var currentPending: PendingTask? { pendingTasks.first }

    /// 最近一次 hook 来源（用于调试 / 顶部贴纸等"当前活跃感"显示），
    /// **不再用于决定单击跳哪个 session**。session 跳转走 pendingTasks 队列。
    @Published var lastSessionID: String?
    @Published var lastCwd: String?

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
        // 解 session 上下文（每个 hook 都含 session_id / cwd）
        let sid = (event.data["session_id"] as? String) ?? ""
        let cwd = (event.data["cwd"] as? String) ?? ""
        // 远程 forwarder 在 payload 里自动加 hostname；本机 hook 没有这个字段
        let host = (event.data["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // 仅记录"最近活跃 session"用于显示，**不用于 resume 跳转**
        if !sid.isEmpty { lastSessionID = sid }
        if !cwd.isEmpty { lastCwd = cwd }

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
            let detailText = detail.isEmpty ? "🛂 \(tool) 等授权" : "🛂 \(detail)"
            enqueuePending(sessionID: sid, cwd: cwd, hostname: host, kind: .notification, detail: detailText)
            transition(to: .notification, bubble: detailText, autoReset: nil)

        case "Notification":
            // 持续显示，直到用户单击 ack（详见 PetView.handleSingleClick）
            enqueuePending(sessionID: sid, cwd: cwd, hostname: host, kind: .notification,
                           detail: "主人我都干完了，你快来看")
            transition(to: .notification,
                       bubble: "主人我都干完了，你快来看",
                       autoReset: nil)

        case "Stop":
            enqueuePending(sessionID: sid, cwd: cwd, hostname: host, kind: .done, detail: "搞定！")
            transition(to: .done, bubble: "搞定！", autoReset: nil)

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

    /// 用户在桌宠上单击 → 弹出队首 pending 任务，返回它给调用方做 resume。
    /// 队列还有剩余 → 保持 .done/.notification 状态展示下一条；
    /// 队列清空 → 回 .idle 并起 sleep timer。
    ///
    /// 必须同步调用 + 同步返回：调用方拿着 (sessionID, cwd) 立即去启动子进程
    /// resume，所以不能 dispatch.async。
    @discardableResult
    func ackPendingTask() -> PendingTask? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !pendingTasks.isEmpty else { return nil }
        let head = pendingTasks.removeFirst()

        if let next = pendingTasks.first {
            // 还有任务排队 → 把气泡切到下一条；state 保持
            bubble = next.detail
            switch next.kind {
            case .done:         state = .done
            case .notification: state = .notification
            }
        } else {
            // 队列清空 → 回 idle
            resetWork?.cancel()
            if state == .notification || state == .done {
                state = .idle
                bubble = ""
            }
            scheduleSleep()
        }
        return head
    }

    /// 兼容老调用方：仅当 state == .notification 且队列空时直接 ack。
    /// 新链路应优先调用 ackPendingTask()。
    func acknowledgeNotification() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.state == .notification else { return }
            if !self.pendingTasks.isEmpty {
                _ = self.ackPendingTask()
                return
            }
            self.resetWork?.cancel()
            self.state = .idle
            self.bubble = ""
            self.scheduleSleep()
        }
    }

    /// 把一条 pending 任务推入队尾。同 (sessionID, kind) 已存在 → 更新现有条目
    /// 的 detail/timestamp，不入新（防止同一 session 反复 Stop 把队列撑爆）。
    private func enqueuePending(sessionID: String, cwd: String, hostname: String?, kind: PendingTask.Kind, detail: String) {
        guard !sessionID.isEmpty else {
            // 没有 session_id 的 hook（理论上不该发生）—— 不入队，但仍走 transition
            return
        }
        if let idx = pendingTasks.firstIndex(where: {
            $0.sessionID == sessionID && $0.kind == kind
        }) {
            // 更新现有条目（保持 id/位置不变，detail 取最新）
            let old = pendingTasks[idx]
            pendingTasks[idx] = PendingTask(
                sessionID: old.sessionID,
                cwd: cwd.isEmpty ? old.cwd : cwd,
                hostname: hostname ?? old.hostname,
                kind: old.kind,
                detail: detail,
                timestamp: Date()
            )
        } else {
            pendingTasks.append(PendingTask(
                sessionID: sessionID,
                cwd: cwd,
                hostname: hostname,
                kind: kind,
                detail: detail,
                timestamp: Date()
            ))
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
