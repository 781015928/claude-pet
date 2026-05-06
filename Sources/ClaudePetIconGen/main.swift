import AppKit
import CoreGraphics
import Foundation

/// 生成 ClaudePet 应用图标 PNG（默认 1024×1024）。
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

    // ===== 1) 圆角矩形背景 + 渐变 =====
    let pad: CGFloat = size * 0.085
    let bgRect = CGRect(x: pad, y: pad, width: size - 2*pad, height: size - 2*pad)
    let radius = size * 0.22
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1.00, green: 0.94, blue: 0.83, alpha: 1.0),
            CGColor(red: 0.96, green: 0.81, blue: 0.55, alpha: 1.0)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: .zero, options: [])
    ctx.restoreGState()

    // 内描边（高光感）
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.4))
    ctx.setLineWidth(size * 0.012)
    ctx.strokePath()
    ctx.restoreGState()

    // ===== 2) 巴哥犬头部 =====
    let cx = size / 2
    let cy = size / 2 - size * 0.04
    let r = size * 0.275

    let mask = CGColor(red: 0.16, green: 0.13, blue: 0.13, alpha: 1)
    let fur = CGColor(red: 0.94, green: 0.83, blue: 0.62, alpha: 1)
    let furDark = CGColor(red: 0.78, green: 0.62, blue: 0.40, alpha: 1)

    // 阴影投在背景上
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.025,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))

    // 双耳（在头之前画，让头压住耳根）
    ctx.setFillColor(mask)
    drawEar(ctx, cx: cx, cy: cy, r: r, side: -1)
    drawEar(ctx, cx: cx, cy: cy, r: r, side: 1)

    // 头主体
    ctx.setFillColor(fur)
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

    ctx.restoreGState()

    // 头部描边
    ctx.setStrokeColor(furDark)
    ctx.setLineWidth(r * 0.012)
    ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

    // 黑色"墨镜"眼罩 —— 两个椭圆
    ctx.setFillColor(mask)
    ctx.fillEllipse(in: CGRect(x: cx - r * 0.72, y: cy - r * 0.10,
                               width: r * 0.58, height: r * 0.42))
    ctx.fillEllipse(in: CGRect(x: cx + r * 0.14, y: cy - r * 0.10,
                               width: r * 0.58, height: r * 0.42))
    // 鼻梁连接（让眼罩看起来连成一片）
    ctx.fill(CGRect(x: cx - r * 0.10, y: cy - r * 0.05,
                    width: r * 0.20, height: r * 0.18))

    // 嘴罩（下方倒水滴）
    let muzzle = CGRect(x: cx - r * 0.42, y: cy - r * 0.72,
                        width: r * 0.84, height: r * 0.62)
    ctx.fillEllipse(in: muzzle)

    // 额头三道皱褶
    ctx.setStrokeColor(furDark)
    ctx.setLineWidth(r * 0.018)
    ctx.setLineCap(.round)
    let wrW = r * 0.42
    let wrY = cy + r * 0.55
    let wrH = r * 0.07
    let wrX0 = cx - wrW / 2
    let segments: [(CGFloat, CGFloat)] = [(0, 1.0/3), (1.0/3, 2.0/3), (2.0/3, 1.0)]
    for (a, b) in segments {
        let x1 = wrX0 + wrW * a
        let x2 = wrX0 + wrW * b
        let mid = (x1 + x2) / 2
        ctx.move(to: CGPoint(x: x1, y: wrY))
        ctx.addQuadCurve(to: CGPoint(x: x2, y: wrY), control: CGPoint(x: mid, y: wrY - wrH))
    }
    ctx.strokePath()

    // 眼白 + 瞳孔 + 高光
    let eyeR = r * 0.14
    let eyeY = cy + r * 0.10
    let eyeDX = r * 0.42

    for sign in [-CGFloat(1), CGFloat(1)] {
        let ex = cx + sign * eyeDX
        // 眼白
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: ex - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2))
        // 瞳孔
        let pR = eyeR * 0.62
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: ex - pR, y: eyeY - pR, width: pR * 2, height: pR * 2))
        // 高光
        let hR = eyeR * 0.22
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: ex + hR * 0.6, y: eyeY + hR * 0.4,
                                   width: hR * 2, height: hR * 2))
    }

    // 鼻子
    let noseW = r * 0.28
    let noseH = r * 0.20
    ctx.setFillColor(mask)
    ctx.fillEllipse(in: CGRect(x: cx - noseW / 2, y: cy - r * 0.42 - noseH / 2,
                               width: noseW, height: noseH))

    // 腮红（淡淡两点）
    ctx.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.55, alpha: 0.35))
    let cheekR = r * 0.10
    ctx.fillEllipse(in: CGRect(x: cx - r * 0.78 - cheekR, y: eyeY - r * 0.20 - cheekR,
                               width: cheekR * 2, height: cheekR * 2))
    ctx.fillEllipse(in: CGRect(x: cx + r * 0.78 - cheekR, y: eyeY - r * 0.20 - cheekR,
                               width: cheekR * 2, height: cheekR * 2))

    // ===== 3) Claude sparkle 右上角 =====
    let sparkleR = size * 0.085
    let sparkleC = CGPoint(x: bgRect.maxX - size * 0.13,
                           y: bgRect.maxY - size * 0.13)
    drawClaudeSparkle(ctx, center: sparkleC, radius: sparkleR)

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

/// 一只下垂的耳朵（旋转椭圆）。
func drawEar(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, side: CGFloat) {
    let ex = cx + side * r * 0.78
    let ey = cy + r * 0.45
    ctx.saveGState()
    ctx.translateBy(x: ex, y: ey)
    ctx.rotate(by: side * .pi / 9)   // 微微外撇
    ctx.fillEllipse(in: CGRect(x: -r * 0.20, y: -r * 0.35,
                               width: r * 0.40, height: r * 0.62))
    ctx.restoreGState()
}

/// Claude 风格 4 长 4 短的 8 角星，带白色光晕底。
func drawClaudeSparkle(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
    // 白色光晕底
    let haloR = radius * 1.40
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(x: center.x - haloR, y: center.y - haloR,
                               width: haloR * 2, height: haloR * 2))
    ctx.restoreGState()

    // 8 点星：4 长 + 4 短
    let path = CGMutablePath()
    let total = 8
    let outerR = radius
    let innerR = radius * 0.22
    for i in 0..<total {
        let angle = CGFloat(i) * (2 * .pi) / CGFloat(total) - .pi / 2
        let r = (i % 2 == 0) ? outerR : innerR
        let x = center.x + cos(angle) * r
        let y = center.y + sin(angle) * r
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else      { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()

    // 渐变填充：Claude 橙
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let claudeOrange = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.92, green: 0.54, blue: 0.40, alpha: 1.0),
            CGColor(red: 0.78, green: 0.36, blue: 0.24, alpha: 1.0)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        claudeOrange,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: outerR,
        options: []
    )
    ctx.restoreGState()
}

// main.swift 文件顶层语句即入口
let args = CommandLine.arguments
let outPath = args.count >= 2 ? args[1] : "build/icon-1024.png"
let url = URL(fileURLWithPath: outPath)
let dir = url.deletingLastPathComponent()
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
renderIcon(size: 1024, to: url)
