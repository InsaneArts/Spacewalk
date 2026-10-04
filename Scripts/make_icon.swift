// Draws the Spacewalk app icon: an isometric cube of three Spaces on a deep indigo sky.
// Usage: swift Scripts/make_icon.swift <out.png> [size]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024
let s = CGFloat(size) / 1024

guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.scaleBy(x: s, y: s)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)!
}

// Body: the macOS icon grid leaves 100 pt of air around an 824 pt rounded square.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 824 * 0.2237
let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.42))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x1A1740)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
// Deep indigo at the bottom left, violet at the top right: the colours of the preview's sky.
ctx.drawLinearGradient(gradient([rgb(0x141236), rgb(0x2A2466), rgb(0x5A2E8C)], [0, 0.55, 1]),
                       start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
// A soft glow behind the cube, so the faces have light to catch.
ctx.drawRadialGradient(gradient([rgb(0x9D7BFF, 0.55), rgb(0x9D7BFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
// Stars: a fixed sequence, so every build draws the same sky.
var seed: UInt64 = 0x5EEDC0DE
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 10000) / 10000 }
for _ in 0..<70 {
    let x = 130 + rnd() * 764, y = 130 + rnd() * 764, r = 1.2 + rnd() * 2.6, a = 0.15 + rnd() * 0.55
    ctx.setFillColor(CGColor(gray: 1, alpha: a))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
ctx.restoreGState()

// The cube: seam edge nearest the viewer, two side faces as parallelograms, a top face as a rhombus.
let cx: CGFloat = 512, w: CGFloat = 215, h: CGFloat = 380, d: CGFloat = 86
let seamBottom: CGFloat = 262, seamTop = seamBottom + h
let left = CGPoint(x: cx - w, y: 0), right = CGPoint(x: cx + w, y: 0)

func face(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
}
let leftFace = face([CGPoint(x: left.x, y: seamBottom + d), CGPoint(x: cx, y: seamBottom), CGPoint(x: cx, y: seamTop), CGPoint(x: left.x, y: seamTop + d)])
let rightFace = face([CGPoint(x: cx, y: seamBottom), CGPoint(x: right.x, y: seamBottom + d), CGPoint(x: right.x, y: seamTop + d), CGPoint(x: cx, y: seamTop)])
let topFace = face([CGPoint(x: cx, y: seamTop), CGPoint(x: right.x, y: seamTop + d), CGPoint(x: cx, y: seamTop + 2 * d), CGPoint(x: left.x, y: seamTop + d)])

// Ground shadow under the cube.
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 60, color: CGColor(gray: 0, alpha: 0.5))
ctx.addPath(leftFace); ctx.addPath(rightFace); ctx.setFillColor(rgb(0x120F30)); ctx.fillPath()
ctx.restoreGState()

func fill(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient(colors, [0, 1]), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
fill(leftFace, [rgb(0xF4F2FF), rgb(0xD9D3F7)], from: CGPoint(x: cx, y: seamTop), to: CGPoint(x: left.x, y: seamBottom))
fill(rightFace, [rgb(0xB9AEE8), rgb(0x8C7CCF)], from: CGPoint(x: cx, y: seamTop), to: CGPoint(x: right.x, y: seamBottom))
fill(topFace, [rgb(0xFFFFFF), rgb(0xEDE9FF)], from: CGPoint(x: cx, y: seamTop + 2 * d), to: CGPoint(x: cx, y: seamTop))

// Window bars on the two side faces: each face is a Space with a few windows on it.
func bars(on face: CGPath, origin: CGPoint, u: CGPoint, v: CGPoint, color: CGColor) {
    // origin + a*u + b*v maps the face's unit square; bars are drawn in that space.
    ctx.saveGState(); ctx.addPath(face); ctx.clip()
    var t = CGAffineTransform(a: u.x, b: u.y, c: v.x, d: v.y, tx: origin.x, ty: origin.y)
    let rows: [(CGFloat, CGFloat, CGFloat)] = [(0.14, 0.76, 0.10), (0.30, 0.52, 0.10), (0.46, 0.64, 0.10)]
    for (y, width, height) in rows {
        let r = CGRect(x: 0.12, y: 1 - y - height, width: width, height: height)
        let p = CGPath(roundedRect: r, cornerWidth: 0.03, cornerHeight: 0.03, transform: &t)
        ctx.addPath(p)
    }
    ctx.setFillColor(color); ctx.fillPath()
    ctx.restoreGState()
}
bars(on: leftFace, origin: CGPoint(x: left.x, y: seamBottom + d), u: CGPoint(x: w, y: -d), v: CGPoint(x: 0, y: h), color: rgb(0x3A2F7A, 0.22))
bars(on: rightFace, origin: CGPoint(x: cx, y: seamBottom), u: CGPoint(x: w, y: d), v: CGPoint(x: 0, y: h), color: rgb(0x2B2160, 0.26))

// Edge light along the seam and the rim of the body.
ctx.saveGState()
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(3)
ctx.move(to: CGPoint(x: cx, y: seamBottom)); ctx.addLine(to: CGPoint(x: cx, y: seamTop)); ctx.strokePath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: radius - 1.5, cornerHeight: radius - 1.5, transform: nil))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(size)x\(size))")
