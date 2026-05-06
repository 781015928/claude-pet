import SwiftUI

/// 帧动画视图 —— 支持 Codex 风格"每帧独立时长"。
/// 用 TimelineView(.animation) 拉时钟，按累计时长查找当前帧（避免 Timer + @State 自相互调）。
struct SpriteAnimationView: View {
    let sheet: SpriteSheet
    let animation: SpriteAnimation
    var size: CGSize = CGSize(width: 144, height: 156) // 192×208 缩 0.75

    @State private var startTime: Date = Date()

    var body: some View {
        TimelineView(.animation) { context in
            Image(nsImage: sheet.frame(row: animation.row, col: frameIndex(at: context.date)))
                .interpolation(.high)
                .resizable()
                .frame(width: size.width, height: size.height)
                // 帧切换不要任何隐式过渡（继承自父级也屏蔽掉）
                .animation(nil, value: animation.row)
        }
        .onChange(of: animation) { _ in
            startTime = Date()
        }
    }

    /// 给定时刻，按 frameDurations 累加查找当前帧索引（loop 模式）。
    private func frameIndex(at date: Date) -> Int {
        let durations = animation.frameDurations
        guard !durations.isEmpty else { return 0 }
        let total = animation.totalDuration
        guard total > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(startTime).truncatingRemainder(dividingBy: total)
        var acc: TimeInterval = 0
        for (i, d) in durations.enumerated() {
            acc += d
            if elapsed < acc { return i }
        }
        return durations.count - 1
    }
}
