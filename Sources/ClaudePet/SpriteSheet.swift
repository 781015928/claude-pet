import AppKit
import Foundation

/// 一张 Codex / petdex 风格的 sprite sheet。
/// 标准规格：1536×1872, 8 列 × 9 行, 每帧 192×208。
/// 切片用 CGImage.cropping —— zero-copy 视图，缓存进二维数组。
final class SpriteSheet {
    let frameSize: CGSize
    let cols: Int
    let rows: Int
    private var frames: [[NSImage]] = []

    init?(url: URL, frameSize: CGSize = CGSize(width: 192, height: 208)) {
        guard let nsImage = NSImage(contentsOf: url) else {
            NSLog("[SpriteSheet] cannot load \(url.path)")
            return nil
        }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            NSLog("[SpriteSheet] cannot get CGImage from \(url.path)")
            return nil
        }
        let cols = Int(round(CGFloat(cg.width) / frameSize.width))
        let rows = Int(round(CGFloat(cg.height) / frameSize.height))
        guard cols > 0, rows > 0 else {
            NSLog("[SpriteSheet] invalid grid: \(cg.width)x\(cg.height) / \(frameSize)")
            return nil
        }
        self.frameSize = frameSize
        self.cols = cols
        self.rows = rows

        for row in 0..<rows {
            var rowFrames: [NSImage] = []
            for col in 0..<cols {
                let crop = CGRect(
                    x: CGFloat(col) * frameSize.width,
                    y: CGFloat(row) * frameSize.height,
                    width: frameSize.width,
                    height: frameSize.height
                )
                if let sub = cg.cropping(to: crop) {
                    rowFrames.append(NSImage(cgImage: sub, size: frameSize))
                } else {
                    rowFrames.append(NSImage(size: frameSize))
                }
            }
            frames.append(rowFrames)
        }
    }

    func frame(row: Int, col: Int) -> NSImage {
        let r = max(0, min(row, rows - 1))
        let c = max(0, min(col, cols - 1))
        return frames[r][c]
    }
}
