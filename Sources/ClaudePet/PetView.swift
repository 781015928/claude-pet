import SwiftUI
import AppKit

/// 桌宠主视图：sprite 渲染 + 气泡 + 顶部贴纸 + 鼠标交互。
struct PetView: View {
    @ObservedObject var stateMachine: PetStateMachine
    @ObservedObject var mouseTracker: MouseTracker
    @ObservedObject var settings: PetSettings

    /// 仅供 ZZZBubbles 等装饰动画使用（sprite 自带时钟，不依赖此 phase）
    @State private var phase: Double = 0

    /// 实际显示的气泡 —— afterTaskOnce 追随期间强制展示"主人我都干完了"文案，
    /// 不被 stateMachine 内部的 autoReset / 后续状态切换覆盖；单击 ack 后回退到
    /// stateMachine.bubble。
    /// 文案里嵌入 session 名（cwd basename），让用户知道是哪个会话来叫他。
    private var displayBubble: String {
        if settings.isFollowing && settings.followMode == .afterTaskOnce {
            let name = stateMachine.sessionName
            return name.isEmpty
                ? "主人我都干完了，你快来看"
                : "\(name) 干完了，你快来看"
        }
        return stateMachine.bubble
    }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())

            if !displayBubble.isEmpty {
                BubbleView(text: displayBubble)
                    .offset(y: -86)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.2), value: displayBubble)
            }

            bodyRenderer
        }
        .frame(width: 180, height: 200)
        .scaleEffect(settings.scale, anchor: .center)
        .frame(
            width: 180 * settings.scale,
            height: 200 * settings.scale
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { handleDoubleClick() }
        .onTapGesture(count: 1) { handleSingleClick() }
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    @ViewBuilder
    private var bodyRenderer: some View {
        if let sheet = settings.sheet(for: settings.skin) {
            SpriteBody(
                sheet: sheet,
                animation: stateMachine.oneshot ?? settings.skin.animation(for: stateMachine.state),
                state: stateMachine.state,
                sleepVariant: stateMachine.sleepVariant,
                phase: phase
            )
            // sprite 帧切换不要任何隐式过渡 —— 否则新旧帧会叠加重影
            .transaction { txn in
                txn.animation = nil
                txn.disablesAnimations = true
            }
        } else {
            EmptyStateView()
        }
    }

    /// 单击优先级：
    /// 1. 任务完成相关场景（.notification / .done / afterTaskOnce 追随中）：
    ///    ↳ 跳回那个 Claude session（claude --resume <id> /desktop）
    ///    ↳ 同时 ack 通知 / 取消追随
    /// 2. 否则 → 随机播放 waving / jumping / review 一个 oneshot
    private func handleSingleClick() {
        let inFollow = settings.isFollowing && settings.followMode == .afterTaskOnce
        let isPostTask =
            stateMachine.state == .notification ||
            stateMachine.state == .done ||
            inFollow

        if isPostTask {
            // 跳回 session
            if let sid = stateMachine.lastSessionID, !sid.isEmpty {
                PetActions.resumeClaudeSession(id: sid, cwd: stateMachine.lastCwd)
            }
            // 清状态（追随优先于 notification —— follow 时 state 通常 == .done 或 .notification 都需要清）
            if inFollow {
                settings.onCancelFollowRequest?()
            }
            if stateMachine.state == .notification {
                stateMachine.acknowledgeNotification()
            }
            return
        }

        let pool: [CodexRow] = [.waving, .jumping, .review]
        if let pick = pool.randomElement() {
            stateMachine.playOneshot(SpriteAnimation(pick))
        }
    }

    /// 双击：唤起 Claude Desktop。
    /// 若 afterTaskOnce 模式正在追随，同步中断并跑回默认位置。
    private func handleDoubleClick() {
        if settings.isFollowing && settings.followMode == .afterTaskOnce {
            settings.onCancelFollowRequest?()
        }
        PetActions.launchClaudeDesktop()
    }
}

// MARK: - Sprite 主体

private struct SpriteBody: View {
    let sheet: SpriteSheet
    let animation: SpriteAnimation
    let state: PetState
    let sleepVariant: SleepVariant
    let phase: Double

    var body: some View {
        ZStack {
            SpriteAnimationView(sheet: sheet, animation: animation)

            topSticker.offset(x: 52, y: -54)

            if state == .sleeping && sleepVariant == .curl {
                ZZZBubbles(phase: phase).offset(x: 40, y: -40)
            }
        }
        .frame(width: 160, height: 160)
    }

    @ViewBuilder
    private var topSticker: some View {
        if state == .thinking {
            StickerBubble(text: "?", color: .blue)
        } else if state == .notification {
            StickerBubble(text: "!", color: .red)
        } else if state == .working {
            StickerBubble(text: "⌨︎", color: .gray)
        } else if state == .sleeping && sleepVariant == .bored {
            StickerBubble(text: "—", color: .gray)
        } else {
            EmptyView()
        }
    }
}

// MARK: - 占位（无形象时）

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text("无可用形象")
                .font(.system(size: 12, weight: .semibold))
            Text("菜单 🐶 → 素材管理")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(width: 144, height: 156)
    }
}

// MARK: - 装饰

private struct ZZZBubbles: View {
    let phase: Double
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let pp = (phase + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                Text("Z")
                    .font(.system(size: 11 + CGFloat(i) * 4, weight: .heavy, design: .rounded))
                    .foregroundColor(.blue.opacity(1 - pp))
                    .offset(x: CGFloat(pp) * 14, y: -CGFloat(pp) * 28)
            }
        }
    }
}

private struct StickerBubble: View {
    let text: String
    let color: Color
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            Text(text)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundColor(color)
        }
    }
}

private struct BubbleView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            )
            .lineLimit(1)
    }
}
