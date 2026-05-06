import AppKit
import SwiftUI
import Combine

/// 桌宠浮窗：透明、置顶、不抢焦点、可拖拽。
final class PetWindow: NSPanel {
    private var cancellables = Set<AnyCancellable>()
    private weak var stateMachine: PetStateMachine?
    private let followController = FollowController()
    private var saveOriginTimer: Timer?

    /// scale=1.0 时的窗口尺寸
    private static let baseSize = NSSize(width: 180, height: 200)
    private static let originKey = "ClaudePet.window.origin"

    init(stateMachine: PetStateMachine, mouseTracker: MouseTracker, settings: PetSettings) {
        self.stateMachine = stateMachine
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

        // scale 变化 → 调整窗口尺寸（保持中心点不变）
        settings.$scale
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.applyScale(s) }
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

    func moveToBottomRight(animated: Bool = false) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let target = NSPoint(x: v.maxX - frame.width - 24, y: v.minY + 24)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.6
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrameOrigin(target)
            }
        } else {
            setFrameOrigin(target)
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
    }

    private func persistOrigin() {
        UserDefaults.standard.set([
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y)
        ], forKey: Self.originKey)
    }

    /// 缩放：保持中心不变，改 frame.size。
    private func applyScale(_ scale: Double) {
        let new = NSSize(
            width: Self.baseSize.width * CGFloat(scale),
            height: Self.baseSize.height * CGFloat(scale)
        )
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        let target = NSRect(
            origin: NSPoint(x: mid.x - new.width / 2, y: mid.y - new.height / 2),
            size: new
        )
        setFrame(target, display: true)
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
