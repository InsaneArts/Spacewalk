import SwiftUI
import SpacewalkCore

/// Loops the configured transition between two mock workspaces, using the real engine.
struct PreviewView: NSViewRepresentable {
    var settings: SpacewalkSettings

    func makeNSView(context: Context) -> PreviewHostView {
        PreviewHostView(settings: settings)
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {
        if view.settings != settings { view.settings = settings }
    }
}

final class PreviewHostView: NSView {
    var settings: SpacewalkSettings {
        didSet { if settings != oldValue { restart() } }
    }
    private var stage: TransitionStage?
    private var direction = Direction.forward
    private var timer: Timer?
    private var images: MockScene?
    private var showingFirst = true

    init(settings: SpacewalkSettings) {
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = CGColor(gray: 0.1, alpha: 1)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard bounds.width > 10, bounds.height > 10 else { return }
        if stage == nil || stage?.size != bounds.size {
            stage?.root.removeFromSuperlayer()
            let stage = TransitionStage(size: bounds.size)
            layer?.addSublayer(stage.root)
            self.stage = stage
            images = MockWorkspace.render(size: bounds.size, scale: window?.backingScaleFactor ?? 2)
            restart()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil } else { restart() }
    }

    /// A changed setting plays at once, so the preview always shows what is selected.
    private func restart() {
        timer?.invalidate()
        guard let stage, let images else { return }
        stage.setWallpapers(outgoing: showingFirst ? images.wallpaperFirst : images.wallpaperSecond, incoming: showingFirst ? images.wallpaperSecond : images.wallpaperFirst)
        stage.setOutgoing(showingFirst ? images.first : images.second)
        stage.showResting()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.play() }
    }

    private func play() {
        guard let stage, let images, window != nil else { return }
        let from = showingFirst ? images.first : images.second
        let to = showingFirst ? images.second : images.first
        stage.setWallpapers(outgoing: showingFirst ? images.wallpaperFirst : images.wallpaperSecond, incoming: showingFirst ? images.wallpaperSecond : images.wallpaperFirst)
        stage.setOutgoing(from)
        stage.setIncoming(to)
        let timing = AnimationTiming(settings: settings)
        UserDefaults.standard.set(settings.effect.rawValue, forKey: "debug.previewEffect")
        stage.run(settings: settings, direction: direction, timing: timing) { [weak self] in
            guard let self else { return }
            showingFirst.toggle()
            direction = direction.flipped
            stage.setOutgoing(to)
            stage.showResting()
            timer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in self?.play() }
        }
    }
}

/// Two fake Spaces and their wallpapers, so the preview and the offscreen renderer need no screen
/// capture. Space 1 is a coding desk, Space 2 a browsing one; both wear a different wallpaper.
struct MockScene {
    let wallpaperFirst: CGImage
    let wallpaperSecond: CGImage
    let first: CGImage
    let second: CGImage
}

enum MockWorkspace {
    static func render(size: CGSize, scale: CGFloat) -> MockScene? {
        let w = size.width, h = size.height
        // Everything is sized from the height, so the wide settings preview and a 16:10 render
        // both look like a desk and not like a diagram.
        let u = max(0.45, h / 900)
        var seed: UInt64 = 0x5EEDBEEF
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 10000) / 10000 }

        func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
        }
        func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
            CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)!
        }
        func glow(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, _ c: CGColor) {
            let fade = c.copy(alpha: 0)!
            ctx.drawRadialGradient(gradient([c, fade], [0, 1]), startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
        }
        func wallpaper(_ base: [UInt32], glows: [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)]) -> CGImage? {
            image(size: size, scale: scale) { ctx in
                ctx.drawLinearGradient(gradient(base.map { color($0) }, [0, 0.5, 1]), start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
                for (x, y, r, hex, a) in glows { glow(ctx, at: CGPoint(x: x * w, y: y * h), radius: r * h, color(hex, a)) }
            }
        }
        guard let wallpaperFirst = wallpaper([0x101538, 0x1F2A6B, 0x2C1E5A], glows: [(0.85, 0.85, 0.75, 0x7B5CFF, 0.45), (0.1, 0.1, 0.7, 0x1FB6C9, 0.35)]),
              let wallpaperSecond = wallpaper([0x2A1030, 0x4A1F5C, 0x1C2A4F], glows: [(0.15, 0.9, 0.8, 0xFF7A59, 0.42), (0.9, 0.2, 0.7, 0xC24BD6, 0.4)]) else { return nil }

        struct Frame { let rect: CGRect; let dark: Bool }
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            // Fractions from the top-left corner, as a designer would lay the desk out.
            CGRect(x: x0 * w, y: (1 - y1) * h, width: (x1 - x0) * w, height: (y1 - y0) * h)
        }
        func window(_ ctx: CGContext, _ frame: Frame, body: (CGContext, CGRect) -> Void) {
            let r = frame.rect
            let radius = 11 * u
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 30 * u, color: CGColor(gray: 0, alpha: 0.45))
            ctx.addPath(path); ctx.setFillColor(frame.dark ? color(0x1C1C21) : color(0xF4F2F5)); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            // Title bar with the three lights.
            let bar = CGRect(x: r.minX, y: r.maxY - 40 * u, width: r.width, height: 40 * u)
            ctx.setFillColor(frame.dark ? color(0x2A2A31) : color(0xE6E3E8)); ctx.fill(bar)
            for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let c = CGPoint(x: r.minX + (20 + CGFloat(i) * 20) * u, y: bar.midY)
                ctx.setFillColor(color(UInt32(hex))); ctx.fillEllipse(in: CGRect(x: c.x - 6 * u, y: c.y - 6 * u, width: 12 * u, height: 12 * u))
            }
            body(ctx, CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 40 * u))
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: frame.dark ? 1 : 0, alpha: 0.12)); ctx.setLineWidth(1 * u); ctx.strokePath()
            ctx.restoreGState()
        }
        func line(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, _ c: CGColor, height: CGFloat = 8) {
            let rr = CGRect(x: x, y: y - height * u / 2, width: width, height: height * u)
            ctx.addPath(CGPath(roundedRect: rr, cornerWidth: height * u / 2, cornerHeight: height * u / 2, transform: nil)); ctx.setFillColor(c); ctx.fillPath()
        }
        func numeral(_ ctx: CGContext, _ text: String) {
            let font = CTFontCreateWithName("SFProRounded-Bold" as CFString, h * 0.42, nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 0.10)]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            ctx.textPosition = CGPoint(x: w - bounds.width - 18 * u, y: 16 * u)
            CTLineDraw(ctLine, ctx)
        }

        // Space 1: an editor, a terminal and a notes window.
        let first = image(size: size, scale: scale) { ctx in
            numeral(ctx, "1")
            window(ctx, Frame(rect: rect(0.03, 0.06, 0.585, 0.94), dark: true)) { ctx, body in
                let side = CGRect(x: body.minX, y: body.minY, width: 150 * u, height: body.height)
                ctx.setFillColor(color(0x232329)); ctx.fill(side)
                var y = body.maxY - 26 * u
                for i in 0..<Int(body.height / (24 * u)) {
                    line(ctx, x: side.minX + 16 * u, y: y, width: (60 + rnd() * 60) * u, CGColor(gray: 1, alpha: i == 2 ? 0.7 : 0.28), height: 7)
                    y -= 24 * u
                }
                let tokens: [UInt32] = [0xC678DD, 0x61AFEF, 0x98C379, 0xE5C07B, 0xABB2BF, 0x56B6C2]
                y = body.maxY - 28 * u
                let left = side.maxX + 36 * u
                while y > body.minY + 12 * u {
                    let indent = CGFloat([0, 1, 1, 2, 2, 1, 0][Int(rnd() * 7)]) * 28 * u
                    var x = left + indent
                    line(ctx, x: side.maxX + 10 * u, y: y, width: 14 * u, CGColor(gray: 1, alpha: 0.18), height: 6)
                    if rnd() < 0.18 {
                        line(ctx, x: x, y: y, width: (120 + rnd() * 160) * u, color(0x6B717D), height: 7)
                    } else {
                        for _ in 0..<(2 + Int(rnd() * 3)) {
                            let width = (26 + rnd() * 70) * u
                            line(ctx, x: x, y: y, width: width, color(tokens[Int(rnd() * CGFloat(tokens.count))], 0.9), height: 7)
                            x += width + 10 * u
                        }
                    }
                    y -= 22 * u
                }
            }
            window(ctx, Frame(rect: rect(0.615, 0.06, 0.97, 0.47), dark: true)) { ctx, body in
                ctx.setFillColor(color(0x121216)); ctx.fill(body)
                var y = body.maxY - 26 * u
                while y > body.minY + 10 * u {
                    let prompt = rnd() < 0.35
                    if prompt {
                        line(ctx, x: body.minX + 18 * u, y: y, width: 12 * u, color(0x5AF78E), height: 7)
                        line(ctx, x: body.minX + 38 * u, y: y, width: (60 + rnd() * 120) * u, CGColor(gray: 1, alpha: 0.85), height: 7)
                    } else {
                        line(ctx, x: body.minX + 18 * u, y: y, width: (80 + rnd() * 200) * u, CGColor(gray: 1, alpha: 0.4), height: 7)
                    }
                    y -= 22 * u
                }
                ctx.setFillColor(color(0x5AF78E, 0.9)); ctx.fill(CGRect(x: body.minX + 18 * u, y: y + 11 * u - 7 * u, width: 9 * u, height: 14 * u))
            }
            window(ctx, Frame(rect: rect(0.615, 0.51, 0.97, 0.94), dark: false)) { ctx, body in
                var y = body.maxY - 30 * u
                line(ctx, x: body.minX + 22 * u, y: y, width: body.width * 0.45, color(0x2B2B30), height: 11); y -= 30 * u
                while y > body.minY + 12 * u {
                    let highlight = rnd() < 0.2
                    let width = (0.45 + rnd() * 0.45) * (body.width - 44 * u)
                    if highlight { line(ctx, x: body.minX + 22 * u, y: y, width: width, color(0xFFE08A), height: 12) }
                    line(ctx, x: body.minX + 22 * u, y: y, width: width, color(0x3A3A40, highlight ? 0.9 : 0.55), height: 7)
                    y -= 21 * u
                }
            }
        }

        // Space 2: a browser and a music window.
        let second = image(size: size, scale: scale) { ctx in
            numeral(ctx, "2")
            window(ctx, Frame(rect: rect(0.03, 0.06, 0.64, 0.94), dark: false)) { ctx, body in
                let toolbar = CGRect(x: body.minX, y: body.maxY - 40 * u, width: body.width, height: 40 * u)
                ctx.setFillColor(color(0xE6E3E8)); ctx.fill(toolbar)
                for i in 0..<2 {
                    ctx.setFillColor(color(0xC9C5CC)); ctx.fillEllipse(in: CGRect(x: body.minX + (18 + CGFloat(i) * 26) * u, y: toolbar.midY - 8 * u, width: 16 * u, height: 16 * u))
                }
                let pill = CGRect(x: body.minX + 80 * u, y: toolbar.midY - 12 * u, width: body.width - 160 * u, height: 24 * u)
                ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 12 * u, cornerHeight: 12 * u, transform: nil)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
                line(ctx, x: pill.midX - 50 * u, y: pill.midY, width: 100 * u, color(0x9A96A0), height: 7)
                let page = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height - 40 * u)
                let hero = CGRect(x: page.minX + 28 * u, y: page.maxY - 28 * u - page.height * 0.34, width: page.width - 56 * u, height: page.height * 0.34)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: hero, cornerWidth: 10 * u, cornerHeight: 10 * u, transform: nil)); ctx.clip()
                ctx.drawLinearGradient(gradient([color(0x5B8DEF), color(0x9B6BFF), color(0xFF8A80)], [0, 0.55, 1]), start: CGPoint(x: hero.minX, y: hero.maxY), end: CGPoint(x: hero.maxX, y: hero.minY), options: [])
                ctx.restoreGState()
                var y = hero.minY - 34 * u
                line(ctx, x: hero.minX, y: y, width: hero.width * 0.5, color(0x25242A), height: 13); y -= 30 * u
                while y > page.minY + page.height * 0.30 {
                    line(ctx, x: hero.minX, y: y, width: hero.width * (0.6 + rnd() * 0.4), color(0x55535B, 0.75), height: 7)
                    y -= 20 * u
                }
                let cardW = (hero.width - 40 * u) / 3
                for i in 0..<3 {
                    let card = CGRect(x: hero.minX + CGFloat(i) * (cardW + 20 * u), y: page.minY + 24 * u, width: cardW, height: page.height * 0.22)
                    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
                    let art = CGRect(x: card.minX, y: card.maxY - card.height * 0.55, width: card.width, height: card.height * 0.55)
                    ctx.saveGState(); ctx.addPath(CGPath(roundedRect: art, cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil)); ctx.clip()
                    ctx.setFillColor(color([0x8FD3F4, 0xF6D365, 0xA18CD1][i])); ctx.fill(art); ctx.restoreGState()
                    line(ctx, x: card.minX + 12 * u, y: art.minY - 16 * u, width: card.width * 0.6, color(0x2B2B30), height: 8)
                    line(ctx, x: card.minX + 12 * u, y: art.minY - 32 * u, width: card.width * 0.8, color(0x8A8890), height: 6)
                }
            }
            window(ctx, Frame(rect: rect(0.67, 0.06, 0.97, 0.94), dark: true)) { ctx, body in
                let tiles: [UInt32] = [0xE07A5F, 0x3D405B, 0x81B29A, 0xF2CC8F, 0x5C6BC0, 0xAB47BC, 0x26A69A, 0xEF5350, 0x7E57C2]
                let cols = 3, gap = 14 * u
                let side = (body.width - 2 * 20 * u - CGFloat(cols - 1) * gap) / CGFloat(cols)
                var y = body.maxY - 22 * u - side
                var index = 0
                while y > body.minY + 90 * u, index < tiles.count {
                    for c in 0..<cols where index < tiles.count {
                        let tile = CGRect(x: body.minX + 20 * u + CGFloat(c) * (side + gap), y: y, width: side, height: side)
                        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil)); ctx.setFillColor(color(tiles[index])); ctx.fillPath()
                        line(ctx, x: tile.minX, y: tile.minY - 12 * u, width: side * 0.7, CGColor(gray: 1, alpha: 0.75), height: 6)
                        index += 1
                    }
                    y -= side + gap + 16 * u
                }
                let player = CGRect(x: body.minX, y: body.minY, width: body.width, height: 70 * u)
                ctx.setFillColor(color(0x26262D)); ctx.fill(player)
                line(ctx, x: player.minX + 20 * u, y: player.midY + 12 * u, width: player.width - 40 * u, CGColor(gray: 1, alpha: 0.18), height: 4)
                line(ctx, x: player.minX + 20 * u, y: player.midY + 12 * u, width: (player.width - 40 * u) * 0.38, color(0xFF7A59), height: 4)
                for i in 0..<3 {
                    ctx.setFillColor(CGColor(gray: 1, alpha: i == 1 ? 0.95 : 0.55))
                    ctx.fillEllipse(in: CGRect(x: player.midX - 8 * u + CGFloat(i - 1) * 34 * u, y: player.midY - 26 * u, width: 16 * u, height: 16 * u))
                }
            }
        }
        guard let first, let second else { return nil }
        return MockScene(wallpaperFirst: wallpaperFirst, wallpaperSecond: wallpaperSecond, first: first, second: second)
    }

    private static func image(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        draw(ctx)
        return ctx.makeImage()
    }
}
