import AppKit
import SwiftUI
import Combine

/// 桌宠浮窗：透明、置顶、不抢焦点、可拖拽。
final class PetWindow: NSPanel {
    private var cancellables = Set<AnyCancellable>()
    private weak var stateMachine: PetStateMachine?
    private weak var settings: PetSettings?
    private let followController = FollowController()
    private var saveOriginTimer: Timer?

    /// 上一次 didMove 时的 origin.x —— 用来算拖拽方向。
    private var lastMoveOriginX: CGFloat?
    /// 程序化重置位置（如 moveToBottomRight）期间屏蔽方向 sprite。
    private var suppressDragSprite: Bool = false

    /// scale=1.0 时的窗口尺寸
    private static let baseSize = NSSize(width: 180, height: 200)
    private static let originKey = "ClaudePet.window.origin"

    init(stateMachine: PetStateMachine, mouseTracker: MouseTracker, settings: PetSettings) {
        self.stateMachine = stateMachine
        self.settings = settings
        let initialSize = NSSize(
            width: Self.baseSize.width * CGFloat(settings.scale),
            height: Self.baseSize.height * CGFloat(settings.scale)
        )
        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false

        let host = CursorAwareHostingView(
            rootView: PetView(stateMachine: stateMachine, mouseTracker: mouseTracker, settings: settings)
        )
        host.frame = self.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        self.contentView = host

        // FollowController 接线
        followController.window = self
        followController.stateMachine = stateMachine
        followController.settings = settings
        settings.onCancelFollowRequest = { [weak self] in
            self?.followController.cancelAndReturn()
        }

        // sleeping=.curl 时自动挪到屏幕右下角去睡。
        Publishers.CombineLatest(stateMachine.$state, stateMachine.$sleepVariant)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, variant in
                if state == .sleeping && variant == .curl {
                    self?.moveToBottomRight(animated: true)
                }
            }
            .store(in: &cancellables)

        // state 变成 running 时窗口实际跑一段。
        stateMachine.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if state == .running {
                    self?.animateRunPath(duration: 6)
                }
            }
            .store(in: &cancellables)

        // 任务完成（state == .done）时按 followMode 启动一次性追随
        stateMachine.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                if state == .done && settings.followMode == .afterTaskOnce {
                    self.followController.start(mode: .afterTaskOnce)
                }
            }
            .store(in: &cancellables)

        // followMode 切换时启停永久追随
        settings.$followMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard let self = self else { return }
                switch mode {
                case .always:
                    self.followController.start(mode: .always)
                case .afterTaskOnce:
                    self.followController.stop()
                case .off:
                    self.followController.cancelAndReturn()
                }
            }
            .store(in: &cancellables)

        // 任何会影响窗口尺寸的输入：scale / 气泡字号 / 气泡内容 / pending 队列 /
        // follow 状态 —— 任一变化都重算 frame。
        // 用 MergeMany 让所有 Void publisher 类型对齐，比 CombineLatest+merge
        // 更不容易被类型推断坑。
        Publishers.MergeMany([
            settings.$scale.map { _ in () }.eraseToAnyPublisher(),
            settings.$bubbleFontSize.map { _ in () }.eraseToAnyPublisher(),
            settings.$followMode.map { _ in () }.eraseToAnyPublisher(),
            settings.$isFollowing.map { _ in () }.eraseToAnyPublisher(),
            stateMachine.$bubble.map { _ in () }.eraseToAnyPublisher(),
            stateMachine.$pendingTasks.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.recomputeFrame() }
        .store(in: &cancellables)

        // 还原上次窗口位置（如果上次保存的位置还在某个屏幕里）
        let didRestore = restoreSavedOrigin(size: initialSize)
        if !didRestore { moveToBottomRight() }

        // 监听窗口移动 → debounced 持久化
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowDidMove(_:)),
            name: NSWindow.didMoveNotification, object: self
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 默认右下角位置。
    ///
    /// 目标矛盾：
    /// - 想让 sprite **视觉中心**始终落在距屏幕右下角 (spriteW/2 + 24, spriteH/2 + 24) 处
    /// - 但 sprite 在 PetView ZStack 里是 alignment .center 渲染的（≈ 窗口几何中心）
    /// - 当气泡撑宽 NSWindow 时，"窗口几何中心" ≠ "屏幕右下角"，二者得选一边
    ///
    /// 算法：**优先保证窗口完整落在屏幕内**（右下各 24pt margin），sprite 视觉
    /// 位置在大气泡时会随窗口整体往左让一些，但不会再有"跑出屏幕"。
    ///
    /// y 方向 dock-safe：visibleFrame.minY 在 dock auto-hide 时只比 frame.minY
    /// 高一点点（~4pt 触发条），如果直接用 v.minY+24 会被 dock 弹出后盖住。改成
    /// `max(v.minY+24, f.minY+80)` —— 不论 dock 隐不隐藏、在哪个屏上都看得见。
    ///
    /// 多显示器：用桌宠当前所在屏，而不是 NSScreen.main（桌宠是 nonactivatingPanel
    /// 永远不是 keyWindow，main 不一定是它所在屏）。
    func defaultBottomRightOrigin() -> NSPoint? {
        guard let screen = currentScreen() else { return nil }
        let v = screen.visibleFrame
        let f = screen.frame
        let s = CGFloat(settings?.scale ?? 1.0)
        let spriteW = Self.baseSize.width * s
        let frameW = frame.width
        let margin: CGFloat = 24

        // 期望：sprite 视觉中心位于 v.maxX - spriteW/2 - margin
        // 推回 origin：origin.x = sprite_center - frameW/2
        let preferred = v.maxX - spriteW / 2 - margin - frameW / 2

        // 但窗口右边不能超出屏幕右减 margin
        let maxOriginX = v.maxX - frameW - margin
        let minOriginX = v.minX + margin
        let originX = max(minOriginX, min(preferred, maxOriginX))

        // dock-safe：起底用 v.minY+24，但 auto-hide / 没 dock 时这个值贴底，
        // dock 一弹出会盖住桌宠。强制不低于 f.minY+120 —— 留出大尺寸 dock + 一点
        // 视觉余量，让桌宠看起来像"踩在 dock 上方"而不是贴 dock 顶部。
        let originY = max(v.minY + margin, f.minY + 120)

        return NSPoint(x: originX, y: originY)
    }

    /// 把任意 origin 夹到"sprite 视觉中心仍在屏内安全区"内 —— 用于阻止
    /// follow tick / 拖拽落盘等路径把桌宠推出屏让用户找不见。
    ///
    /// 安全区 = sprite 中心位于 visibleFrame 减 sprite 半身后的内框；y 方向额外
    /// 不低于 frame.minY+120 保证 dock 弹出也看得见。
    ///
    /// 选屏：先看当前 origin 对应的 sprite 中心在哪个屏，没有就找最近屏；这样
    /// 即使桌宠已经在屏外，clamp 也会把它拉回**最近**那块屏，而不是误跳到 main。
    func clampedOrigin(_ p: NSPoint) -> NSPoint {
        let cx = p.x + frame.width / 2
        let cy = p.y + frame.height / 2
        let testCenter = NSPoint(x: cx, y: cy)

        let screen = NSScreen.screens.first(where: { $0.frame.contains(testCenter) })
            ?? NSScreen.screens.min(by: {
                let am = NSPoint(x: $0.frame.midX, y: $0.frame.midY)
                let bm = NSPoint(x: $1.frame.midX, y: $1.frame.midY)
                return pow(am.x - cx, 2) + pow(am.y - cy, 2)
                     < pow(bm.x - cx, 2) + pow(bm.y - cy, 2)
            })
            ?? NSScreen.main
        guard let screen = screen else { return p }

        let v = screen.visibleFrame
        let f = screen.frame
        let s = CGFloat(settings?.scale ?? 1.0)
        let spriteW = Self.baseSize.width * s
        let spriteH = Self.baseSize.height * s

        // sprite 视觉中心的合法范围
        let minCx = v.minX + spriteW / 2
        let maxCx = v.maxX - spriteW / 2
        let minCy = max(v.minY + spriteH / 2, f.minY + 120)
        let maxCy = v.maxY - spriteH / 2

        let clampedCx = max(minCx, min(cx, maxCx))
        let clampedCy = max(minCy, min(cy, maxCy))

        return NSPoint(
            x: clampedCx - frame.width / 2,
            y: clampedCy - frame.height / 2
        )
    }

    /// 桌宠当前所在屏 —— 优先用窗口中心点定屏；如果中心已在所有屏外（被推出屏 /
    /// 屏拓扑变化等），找几何中心距桌宠中心**最近**的屏，而不是 fallback 到
    /// NSScreen.main —— main 可能是用户键盘焦点屏，跟桌宠原来在哪完全无关。
    private func currentScreen() -> NSScreen? {
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mid) }) {
            return s
        }
        return NSScreen.screens.min { a, b in
            let am = NSPoint(x: a.frame.midX, y: a.frame.midY)
            let bm = NSPoint(x: b.frame.midX, y: b.frame.midY)
            let da = pow(am.x - mid.x, 2) + pow(am.y - mid.y, 2)
            let db = pow(bm.x - mid.x, 2) + pow(bm.y - mid.y, 2)
            return da < db
        } ?? NSScreen.main
    }

    func moveToBottomRight(animated: Bool = false) {
        guard let target = defaultBottomRightOrigin() else { return }
        suppressDragSprite = true
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrameOrigin(target)
            }, completionHandler: { [weak self] in
                self?.suppressDragSprite = false
            })
        } else {
            setFrameOrigin(target)
            suppressDragSprite = false
        }
    }

    /// 把保存的 origin 套回来，前提是 sprite **中心**仍在某个屏的 visibleFrame 内。
    /// 用 contains(center) 而不是 frame.intersects —— 后者哪怕窗口只有 1px 重叠
    /// 也算"在屏"，结果就是桌宠几乎全在屏外被还原，用户找不见。
    @discardableResult
    private func restoreSavedOrigin(size: NSSize) -> Bool {
        guard
            let dict = UserDefaults.standard.dictionary(forKey: Self.originKey),
            let x = dict["x"] as? Double,
            let y = dict["y"] as? Double
        else { return false }
        let p = NSPoint(x: x, y: y)
        let center = NSPoint(x: p.x + size.width / 2, y: p.y + size.height / 2)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(center) }
        guard onScreen else { return false }
        setFrameOrigin(p)
        return true
    }

    @objc private func handleWindowDidMove(_ note: Notification) {
        // 实时安全网：window center 完全跑出所有屏 visibleFrame 时，**立刻**
        // clamp 拉回。允许用户拖到屏边缘部分露头，但拖到完全消失会被弹回 ——
        // 否则 persistOrigin 是 0.5s debounce + 落盘只影响下次启动，本次会话
        // 桌宠就在屏外找不见了。
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let centerInside = NSScreen.screens.contains { $0.visibleFrame.contains(center) }
        if !centerInside {
            let safe = clampedOrigin(frame.origin)
            // 阈值判断防止 setFrameOrigin → didMove → 再次 clamp 的递归
            if abs(safe.x - frame.origin.x) > 0.5 || abs(safe.y - frame.origin.y) > 0.5 {
                setFrameOrigin(safe)
                return // 重新进 didMove，下次直接走正常分支
            }
        }

        // debounce 0.5s —— follow 高频 setFrameOrigin 期间不会落盘，停下后才存
        saveOriginTimer?.invalidate()
        saveOriginTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.persistOrigin()
        }

        // 拖拽方向 → running-left / running-right oneshot
        // playOneshot 同 row 只续期不重置 sprite —— 持续拖动时动画顺畅，
        // 松手后 1.06s oneshot 过期自然回 idle / 当前 state。
        let x = frame.origin.x
        if !suppressDragSprite, let last = lastMoveOriginX {
            let dx = x - last
            if abs(dx) >= 1 {
                let row: CodexRow = dx > 0 ? .runningRight : .runningLeft
                stateMachine?.playOneshot(SpriteAnimation(row))
            }
        }
        lastMoveOriginX = x
    }

    private func persistOrigin() {
        // 落盘前 clamp —— 用户拖到屏外时不强制纠正（保留拖拽自由），但保存的位置
        // 一定是屏内合法位置，下次启动 restoreSavedOrigin 不会还原一个看不见的地方
        let safe = clampedOrigin(frame.origin)
        UserDefaults.standard.set([
            "x": Double(safe.x),
            "y": Double(safe.y)
        ], forKey: Self.originKey)
    }

    /// 重算窗口尺寸：保持中心不变。
    /// - 宽度 = max(baseW × scale, 气泡测量宽度 + padding) —— 气泡比 sprite 宽时
    ///   窗口跟着扩，避免 NSWindow clip 掉气泡两端。
    /// - 高度 = baseH × scale —— 字号过大时气泡顶部可能微溢出，但 SwiftUI 在
    ///   ZStack 里默认不强制 clip 子视图（NSWindow 本身才会硬裁），实际表现可
    ///   接受；要再扩高度的话会牵动 follow / animateRunPath 的位置语义。
    private func recomputeFrame() {
        guard let st = settings else { return }
        let s = CGFloat(st.scale)
        let baseW = Self.baseSize.width * s
        let baseH = Self.baseSize.height * s
        let bubbleW = currentBubbleWidth()
        let newW = max(baseW, bubbleW)
        let newH = baseH

        let mid = NSPoint(x: frame.midX, y: frame.midY)
        let target = NSRect(
            origin: NSPoint(x: mid.x - newW / 2, y: mid.y - newH / 2),
            size: NSSize(width: newW, height: newH)
        )
        setFrame(target, display: true)
    }

    /// 测量当前实际要显示的气泡文本所需宽度（含 padding）。
    /// 文案规则与 PetView.displayBubble 保持一致。
    private func currentBubbleWidth() -> CGFloat {
        guard let st = settings, let sm = stateMachine else { return 0 }
        let text: String
        if let pending = sm.currentPending {
            let count = sm.pendingTasks.count
            let suffix = count > 1 ? " (+\(count - 1))" : ""
            let name = pending.sessionName
            switch pending.kind {
            case .done:
                text = (name.isEmpty ? "主人我都干完了，你快来看" : "\(name) 干完了，你快来看") + suffix
            case .notification:
                text = name.isEmpty ? pending.detail + suffix : "\(name): \(pending.detail)\(suffix)"
            }
        } else {
            text = sm.bubble
        }
        if text.isEmpty { return 0 }

        let f = CGFloat(st.bubbleFontSize)
        // 与 SwiftUI Text(.font(.system(size:weight:.medium, design:.rounded))) 对齐 ——
        // rounded 比默认 system 略宽，用错字体宽度估小会导致裁字。
        let base = NSFont.systemFont(ofSize: f, weight: .medium)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: f) ?? base
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let bbox = attr.boundingRect(
            with: CGSize(width: 10_000, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // BubbleView 的 padding.horizontal = fontSize * 0.9（左右各一份），再多留 12pt 余量
        return ceil(bbox.width + f * 1.8 + 12)
    }

    /// 跑一段路：朝左跑到屏幕左边附近，再跑回原位。
    /// 总时长 ~6s，分两半。完成后由 stateMachine 自己回 idle。
    /// 用 currentScreen() 而不是 NSScreen.main —— 桌宠在副屏时 main 是别的屏，
    /// 否则 leftPoint 算到主屏左边，桌宠会瞬间跨屏跑过去。
    func animateRunPath(duration: TimeInterval = 6) {
        guard let screen = currentScreen() else { return }
        let v = screen.visibleFrame
        let original = self.frame.origin
        let leftPoint = NSPoint(x: v.minX + 40, y: original.y)

        let half = duration / 2

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = half
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            self.animator().setFrameOrigin(leftPoint)
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = half
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                self.animator().setFrameOrigin(original)
            }
        })
    }
}

/// SwiftUI .onHover 在 nonactivating 透明 panel 里不可靠 ——
/// 用 NSView 标准 cursor rect + tracking area 来稳妥切换光标。
final class CursorAwareHostingView<Content: View>: NSHostingView<Content> {
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
