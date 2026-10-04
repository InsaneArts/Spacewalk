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
    private var images: (wallpaper: CGImage, first: CGImage, second: CGImage)?
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
        stage.setWallpaper(images.wallpaper)
        stage.setOutgoing(showingFirst ? images.first : images.second)
        stage.showResting()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.play() }
    }

    private func play() {
        guard let stage, let images, window != nil else { return }
        let from = showingFirst ? images.first : images.second
        let to = showingFirst ? images.second : images.first
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

/// Draws two fake workspaces and a wallpaper so the preview needs no screen capture.
enum MockWorkspace {
    static func render(size: CGSize, scale: CGFloat) -> (CGImage, CGImage, CGImage)? {
        guard let wallpaper = image(size: size, scale: scale, draw: { ctx in
            let colors = [CGColor(red: 0.11, green: 0.13, blue: 0.32, alpha: 1), CGColor(red: 0.38, green: 0.16, blue: 0.42, alpha: 1)]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }) else { return nil }

        func workspace(label: String, windows: [(CGRect, CGFloat)]) -> CGImage? {
            image(size: size, scale: scale) { ctx in
                for (rect, hue) in windows {
                    let frame = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
                    let path = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
                    ctx.addPath(path)
                    ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
                    ctx.fillPath()
                    let bar = CGRect(x: frame.minX, y: frame.maxY - 16, width: frame.width, height: 16)
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.clip()
                    ctx.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1).cgColor)
                    ctx.fill(bar)
                    ctx.restoreGState()
                    for line in 0..<Int((frame.height - 24) / 10) {
                        let width = frame.width * CGFloat([0.5, 0.7, 0.3, 0.6][line % 4])
                        ctx.setFillColor(CGColor(gray: 0.32, alpha: 1))
                        ctx.fill(CGRect(x: frame.minX + 10, y: frame.maxY - 30 - CGFloat(line) * 10, width: width - 20, height: 4))
                    }
                }
                let font = CTFontCreateWithName("SFProRounded-Bold" as CFString, size.height * 0.45, nil)
                let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.12)]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes as [NSAttributedString.Key: Any]))
                let bounds = CTLineGetBoundsWithOptions(line, [])
                ctx.textPosition = CGPoint(x: size.width - bounds.width - 14, y: 14)
                CTLineDraw(line, ctx)
            }
        }

        guard let first = workspace(label: "1", windows: [
            (CGRect(x: 0.04, y: 0.08, width: 0.56, height: 0.84), 0.58),
            (CGRect(x: 0.63, y: 0.08, width: 0.33, height: 0.4), 0.33),
            (CGRect(x: 0.63, y: 0.52, width: 0.33, height: 0.4), 0.08),
        ]), let second = workspace(label: "2", windows: [
            (CGRect(x: 0.04, y: 0.08, width: 0.3, height: 0.84), 0.75),
            (CGRect(x: 0.37, y: 0.08, width: 0.59, height: 0.84), 0.5),
        ]) else { return nil }
        return (wallpaper, first, second)
    }

    private static func image(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        return ctx.makeImage()
    }
}
