import AppKit
import Combine

/// 1–2s 一次轮询全局鼠标位置，并以宠物窗口中心为原点，给出归一化方向向量。
///
/// 输出 `direction` 已经做过 y 翻转 —— 屏幕坐标 y 朝上、SwiftUI y 朝下，
/// 直接用在 `.offset(y:)` 上即可。
final class MouseTracker: ObservableObject {
    /// 单位向量 × 距离衰减系数（0...1）。乘上你想要的最大像素位移即得 offset。
    @Published var direction: CGSize = .zero

    private var timer: Timer?
    private let windowFrameProvider: () -> NSRect?

    init(windowFrameProvider: @escaping () -> NSRect?) {
        self.windowFrameProvider = windowFrameProvider
    }

    func start(interval: TimeInterval = 1.5) {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick() // 立刻先来一次
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let frame = windowFrameProvider() else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - frame.midX
        let dy = mouse.y - frame.midY
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1 else {
            DispatchQueue.main.async { self.direction = .zero }
            return
        }
        // 距离 200pt 以内线性衰减，超出按 1.0 满力追
        let mag = min(dist / 200.0, 1.0)
        let unitX = dx / dist
        let unitY = dy / dist
        let result = CGSize(width: unitX * mag, height: -unitY * mag)
        DispatchQueue.main.async { self.direction = result }
    }
}
