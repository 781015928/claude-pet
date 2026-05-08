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

        // 任何会影响窗口尺寸的输入：scale / 气泡字号 / 气泡内容 / session 名 /
        // follow 状态（影响 displayBubble 文案）—— 任一变化都重算 frame。
        // 用 MergeMany 让 6 个 Void publisher 类型对齐，比 CombineLatest+merge
        // 更不容易被类型推断坑。
        Publishers.MergeMany([
            settings.$scale.map { _ in () }.eraseToAnyPublisher(),
            settings.$bubbleFontSize.map { _ in () }.eraseToAnyPublisher(),
            settings.$followMode.map { _ in () }.eraseToAnyPublisher(),
            settings.$isFollowing.map { _ in () }.eraseToAnyPublisher(),
            stateMachine.$bubble.map { _ in () }.eraseToAnyPublisher(),
            stateMachine.$lastCwd.map { _ in () }.eraseToAnyPublisher(),
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

    /// 默认右下角位置 —— 让 sprite **视觉本体**（baseSize × scale）距屏幕右下角
    /// 各 24pt。如果窗口因气泡撑得比 sprite 宽，多出来的宽度左右等分摊，使
    /// sprite 中心始终落在 (maxX - spriteW/2 - 24, minY + 24 + spriteH/2)。
    /// 这样不论气泡有没有出现 / 多宽，"原地"是同一个视觉位置。
    func defaultBottomRightOrigin() -> NSPoint? {
        guard let screen = NSScreen.main else { return nil }
        let v = screen.visibleFrame
        let s = CGFloat(settings?.scale ?? 1.0)
        let spriteW = Self.baseSize.width * s
        let extraW = max(0, frame.width - spriteW)
        return NSPoint(
            x: v.maxX - spriteW - 24 - extraW / 2,
            y: v.minY + 24
        )
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

    /// 把保存的 origin 套回来，前提是该位置仍在某个可见屏幕里。
    @discardableResult
    private func restoreSavedOrigin(size: NSSize) -> Bool {
        guard
            let dict = UserDefaults.standard.dictionary(forKey: Self.originKey),
            let x = dict["x"] as? Double,
            let y = dict["y"] as? Double
        else { return false }
        let p = NSPoint(x: x, y: y)
        let rect = NSRect(origin: p, size: size)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        guard onScreen else { return false }
        setFrameOrigin(p)
        return true
    }

    @objc private func handleWindowDidMove(_ note: Notification) {
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
        UserDefaults.standard.set([
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y)
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
        if st.isFollowing && st.followMode == .afterTaskOnce {
            let name = sm.sessionName
            text = name.isEmpty
                ? "主人我都干完了，你快来看"
                : "\(name) 干完了，你快来看"
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
    func animateRunPath(duration: TimeInterval = 6) {
        guard let screen = NSScreen.main else { return }
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
