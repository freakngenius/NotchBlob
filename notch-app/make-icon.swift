// Draws the app icon: a black ink blob on warm paper. Run by ./make-icon.sh; the result is committed as AppIcon.icns.
import AppKit

func blobPath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let n = 240
    for i in 0...n {
        let t = Double(i) / Double(n) * 2 * .pi
        let k = 1 + 0.13 * sin(2 * t + 0.6) + 0.09 * sin(3 * t + 2.1) + 0.05 * sin(5 * t + 4.0) + 0.04 * sin(t + 1.0)
        let pt = CGPoint(x: cx + cos(t) * r * k, y: cy + sin(t) * r * k * 0.94)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.0977, side = s - 2 * inset
    let tile = CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side), cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tile); ctx.setFillColor(CGColor(red: 0.949, green: 0.925, blue: 0.875, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let blob = blobPath(cx: s / 2, cy: s / 2, r: side * 0.30)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05, color: CGColor(red: 0.14, green: 0.09, blue: 0.04, alpha: 0.4))
    ctx.addPath(blob); ctx.setFillColor(CGColor(gray: 0.02, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    // soft oily highlight, upper left
    ctx.addPath(blob); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: s * 0.41, y: s * 0.6), startRadius: 0, endCenter: CGPoint(x: s * 0.41, y: s * 0.6), endRadius: side * 0.22, options: [])
    ctx.restoreGState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))\(name.hasSuffix("@2x") ? "@2x" : "").png"))
}
