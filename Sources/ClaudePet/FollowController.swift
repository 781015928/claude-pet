import AppKit
import Foundation

/// 鼠标追随控制器：每 0.4s tick 一次，朝鼠标方向移动窗口，靠近阈值时播 jumping。
final class FollowController {
    weak var window: PetWindow?
    weak var stateMachine: PetStateMachine?
    weak var settings: PetSettings?

    private(set) var mode: FollowMode = .off
    private var timer: Timer?
    private var wasNear: Bool = false

    private let tickInterval: TimeInterval = 1.0 / 60.0  // 60Hz tick
    private let arriveDistance: CGFloat = 80              // 距离 < 此值算"追到"
    private let stepCap: CGFloat = 4                      // 每 tick 走 4pt → ~240pt/秒

    /// 启动追随。
    func start(mode: FollowMode) {
        guard mode != .off else { stop(); return }
        // 已经在跑同模式 → 不重启（避免 .done sink 重复触发）
        if self.mode == mode, timer != nil { return }
        self.mode = mode
        wasNear = false
        timer?.invalidate()
        settings?.isFollowing = true
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // 立即来一次，体验更跟手
        tick()
    }

    /// 停止追随（不带返回动作）。
    func stop() {
        mode = .off
        timer?.invalidate()
        timer = nil
        wasNear = false
        settings?.isFollowing = false
    }

    /// 中断追随并跑回默认位置（屏幕右下角）。
    func cancelAndReturn() {
        guard mode != .off else { return }
        stop()
        runBackToDefault()
    }

    // MARK: - Internal

    private func tick() {
        guard let window = window else { stop(); return }
        let mouse = NSEvent.mouseLocation
        let petCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let dx = mouse.x - petCenter.x
        let dy = mouse.y - petCenter.y
        let dist = sqrt(dx * dx + dy * dy)

        if dist < arriveDistance {
            // 从远到近 → 触发 jumping 一次
            // afterTaskOnce / always 都不在到达后自动停 —— 持续追到用户单击为止
            if !wasNear {
                stateMachine?.playOneshot(SpriteAnimation(.jumping))
                wasNear = true
            }
            return
        }
        wasNear = false

        // 每 tick 持续续期 oneshot —— playOneshot 对同 row 只刷生命周期不重置 sprite，
        // 既避免 oneshot 1 秒后过期回到 idle/done，也不会让 sprite 闪
        let isRight = dx > 0
        let row: CodexRow = isRight ? .runningRight : .runningLeft
        stateMachine?.playOneshot(SpriteAnimation(row))

        let stepDist = min(dist - arriveDistance, stepCap)
        guard stepDist > 0 else { return }
        let stepX = (dx / dist) * stepDist
        let stepY = (dy / dist) * stepDist

        let target = NSPoint(
            x: window.frame.origin.x + stepX,
            y: window.frame.origin.y + stepY
        )
        // followSafeOrigin：x 软 clamp 到所有屏 visibleFrame x 联合范围（允许
        // 跨屏 follow，单屏时即等价于该屏 visibleFrame.x 的严格 clamp），
        // y 严格 clamp 防 dock 沉入。鼠标到屏边缘 / 屏外触发条时桌宠不会再
        // 跟着跑出屏。
        window.setFrameOrigin(window.followSafeOrigin(target))
    }

    /// 用 setFrameOrigin 分步走回默认位置 —— 同 tick 路径，避免 NSAnimationContext 路径不可靠。
    /// 每帧重新 playOneshot 续期 sprite，跑得多远都保持 running-left/right。
    ///
    /// target 每帧都向 PetWindow 重新询问 —— 因为 stop() 触发的
    /// recomputeFrame 是异步生效的，途中窗口宽度可能从"含大气泡"缩到 baseW，
    /// 如果只在出发时算一次 target，到达后就会偏离视觉右下角。
    private func runBackToDefault() {
        guard let window = window, let initial = window.defaultBottomRightOrigin() else { return }

        // 出发方向只在启动时定一次 —— sprite 已经反正会续期，避免中途因为窗口
        // 缩窄、target.x 跳变而镜像翻转。
        let dx0 = initial.x - window.frame.origin.x
        let row: CodexRow = dx0 >= 0 ? .runningRight : .runningLeft

        let speed: CGFloat = 190                   // ~190pt/秒
        let stepInterval: TimeInterval = 0.018     // ~55Hz, 每步 3.4pt
        let perStep = speed * CGFloat(stepInterval)

        let returnTimer = Timer(timeInterval: stepInterval, repeats: true) { [weak self, weak window] t in
            guard let window = window, let target = window.defaultBottomRightOrigin() else {
                t.invalidate(); return
            }
            let origin = window.frame.origin
            let rdx = target.x - origin.x
            let rdy = target.y - origin.y
            let rdist = sqrt(rdx * rdx + rdy * rdy)
            if rdist <= perStep {
                window.setFrameOrigin(target)
                t.invalidate()
                return
            }
            let nx = origin.x + (rdx / rdist) * perStep
            let ny = origin.y + (rdy / rdist) * perStep
            window.setFrameOrigin(NSPoint(x: nx, y: ny))
            // 每帧续期 oneshot —— 同 row 不重置 sprite 内部时钟（跟 tick() 同样手法）
            self?.stateMachine?.playOneshot(SpriteAnimation(row))
        }
        RunLoop.main.add(returnTimer, forMode: .common)
    }
}
