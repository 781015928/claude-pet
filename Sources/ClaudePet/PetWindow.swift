import AppKit
import SwiftUI
import Combine

/// 桌宠浮窗：透明、置顶、不抢焦点、可拖拽。
final class PetWindow: NSPanel {
    private var cancellables = Set<AnyCancellable>()
    private weak var stateMachine: PetStateMachine?
    private let followController = FollowController()

    init(stateMachine: PetStateMachine, mouseTracker: MouseTracker, settings: PetSettings) {
        self.stateMachine = stateMachine
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 200),
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
                    // 等待 .done 触发；当前若在追随中先停下
                    self.followController.stop()
                case .off:
                    self.followController.cancelAndReturn()
                }
            }
            .store(in: &cancellables)
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
