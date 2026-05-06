import AppKit
import CoreGraphics
import Foundation

/// 生成 ClaudePet 应用图标 PNG（默认 1024×1024）。
/// 设计：暖橙径向渐变背景 + 白色 Claude sparkle + 中心 Claude-orange 宠物爪印。
/// 不绑定具体犬种，"宠物 + Claude"通用语义。
/// 用法：swift run ClaudePetIconGen [outputPath]
func renderIcon(size: CGFloat, to outURL: URL) {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fputs("failed to allocate bitmap\n", stderr)
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext

    // ===== 1) 圆角矩形背景：Claude 橙径向渐变 =====
    let pad: CGFloat = size * 0.085
    let bgRect = CGRect(x: pad, y: pad, width: size - 2*pad, height: size - 2*pad)
    let radius = size * 0.22
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let bgGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.97, green: 0.68, blue: 0.50, alpha: 1.0),  // 中心亮
            CGColor(red: 0.86, green: 0.46, blue: 0.32, alpha: 1.0),  // Claude 橙
            CGColor(red: 0.66, green: 0.30, blue: 0.20, alpha: 1.0)   // 边缘深
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawRadialGradient(
        bgGrad,
        startCenter: CGPoint(x: size * 0.5, y: size * 0.55), startRadius: 0,
        endCenter: CGPoint(x: size * 0.5, y: size * 0.50), endRadius: size * 0.72,
        options: []
    )
    ctx.restoreGState()

    // 顶部高光（柔和的白色弧形，模拟立体光泽）
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let highlightGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        highlightGrad,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: size * 0.55),
        options: []
    )
    ctx.restoreGState()

    // 内描边（高光感）
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
    ctx.setLineWidth(size * 0.012)
    ctx.strokePath()
    ctx.restoreGState()

    // ===== 2) 中心大 Claude sparkle —— 白色，带柔和光晕 =====
    let center = CGPoint(x: size / 2, y: size / 2)
    let sparkleR = size * 0.34

    // 光晕：在 sparkle 后面画一个发光的渐变
    ctx.saveGState()
    let glowGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.45),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: sparkleR * 1.4,
        options: []
    )
    ctx.restoreGState()

    drawSparkle(
        ctx,
        center: center,
        outerR: sparkleR,
        innerR: sparkleR * 0.22,
        fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1.0)
    )

    // ===== 3) sparkle 中心嵌入 Claude-orange 爪印 =====
    let claudeOrange = CGColor(red: 0.86, green: 0.46, blue: 0.32, alpha: 1.0)
    drawPawPrint(ctx, center: center, scale: sparkleR * 0.74, color: claudeOrange)

    // ===== 输出 =====
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("failed to encode png\n", stderr)
        exit(1)
    }
    do {
        try png.write(to: outURL)
        print("✓ \(outURL.path) (\(Int(size))×\(Int(size)))")
    } catch {
        fputs("write failed: \(error)\n", stderr)
        exit(1)
    }
}

/// Claude 风格 4 长 4 短 8 角星。
func drawSparkle(_ ctx: CGContext, center: CGPoint, outerR: CGFloat, innerR: CGFloat, fill: CGColor) {
    let path = CGMutablePath()
    let total = 8
    for i in 0..<total {
        let angle = CGFloat(i) * (2 * .pi) / CGFloat(total) - .pi / 2
        let r = (i % 2 == 0) ? outerR : innerR
        let x = center.x + cos(angle) * r
        let y = center.y + sin(angle) * r
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else      { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    ctx.setFillColor(fill)
    ctx.addPath(path)
    ctx.fillPath()
}

/// 通用宠物爪印：1 个主掌椭圆（下方）+ 4 个脚趾椭圆（上方弧形排布）。
/// 不绑定具体犬种，纯符号化。
func drawPawPrint(_ ctx: CGContext, center: CGPoint, scale: CGFloat, color: CGColor) {
    ctx.setFillColor(color)

    // 主掌（梯形感椭圆，下方较大）
    let palmW = scale * 0.95
    let palmH = scale * 0.78
    let palmCY = center.y - scale * 0.30
    ctx.fillEllipse(in: CGRect(
        x: center.x - palmW / 2,
        y: palmCY - palmH / 2,
        width: palmW,
        height: palmH
    ))

    // 4 趾：以圆弧形分布在主掌上方
    // 前两个内趾稍高、稍小；外两个外趾稍低、稍大 —— 模拟真实爪印形态
    let toes: [(dx: CGFloat, dy: CGFloat, r: CGFloat)] = [
        (dx: -0.45, dy:  0.30, r: 0.26),  // 左外趾
        (dx: -0.18, dy:  0.55, r: 0.24),  // 左内趾
        (dx:  0.18, dy:  0.55, r: 0.24),  // 右内趾
        (dx:  0.45, dy:  0.30, r: 0.26)   // 右外趾
    ]
    for toe in toes {
        let toeR = scale * toe.r
        ctx.fillEllipse(in: CGRect(
            x: center.x + toe.dx * scale - toeR,
            y: center.y + toe.dy * scale - toeR,
            width: toeR * 2,
            height: toeR * 2
        ))
    }
}

// 入口
let args = CommandLine.arguments
let outPath = args.count >= 2 ? args[1] : "build/icon-1024.png"
let url = URL(fileURLWithPath: outPath)
let dir = url.deletingLastPathComponent()
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
renderIcon(size: 1024, to: url)
