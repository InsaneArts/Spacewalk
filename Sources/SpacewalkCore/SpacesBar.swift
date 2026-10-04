import AppKit

public struct BarEntry {
    public let label: String
    public let apps: [SpaceEngine.AppBadge]
    public let isCurrent: Bool
    public init(label: String, apps: [SpaceEngine.AppBadge], isCurrent: Bool) {
        self.label = label
        self.apps = apps
        self.isCurrent = isCurrent
    }
}

/// A thin floating bar: every Space with its app icons, the current one highlighted, click to switch.
@MainActor
public final class SpacesBarWindow {
    public var onSelect: ((Int) -> Void)?

    private let panel: NSPanel
    private let view: SpacesBarView
    private var screen: NSScreen

    public init(screen: NSScreen) {
        self.screen = screen
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = SpacesBarView(frame: .zero)
        view.onSelect = { [weak self] index in self?.onSelect?(index) }
        panel.contentView = view
    }

    public var isVisible: Bool { panel.isVisible }

    public func update(screen: NSScreen) { self.screen = screen }

    public func show(entries: [BarEntry], atTop: Bool) {
        let size = view.populate(entries: entries, scale: screen.backingScaleFactor)
        let x = screen.frame.midX - size.width / 2
        let y = atTop ? screen.visibleFrame.maxY - size.height - 6 : screen.frame.minY + 10
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    public func hide() { panel.orderOut(nil) }
}

final class SpacesBarView: NSView {
    var onSelect: ((Int) -> Void)?
    private let backdrop = NSVisualEffectView()
    private var itemFrames: [CGRect] = []
    private var items: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.masksToBounds = true
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { nil }

    /// Lays the items out and returns the bar size.
    func populate(entries: [BarEntry], scale: CGFloat) -> CGSize {
        items.forEach { $0.removeFromSuperlayer() }
        items.removeAll()
        itemFrames.removeAll()
        let height: CGFloat = 30
        let iconSize: CGFloat = 16
        var x: CGFloat = 6
        for (index, entry) in entries.enumerated() {
            let font = NSFont.systemFont(ofSize: 12, weight: entry.isCurrent ? .semibold : .medium)
            let textWidth = ceil((entry.label as NSString).size(withAttributes: [.font: font]).width)
            let icons = Array(entry.apps.prefix(5))
            let width = 12 + textWidth + (icons.isEmpty ? 0 : 8 + CGFloat(icons.count) * (iconSize + 4) - 4) + 12
            let item = CALayer()
            item.delegate = NoImplicitAnimations.shared
            item.frame = CGRect(x: x, y: 4, width: width, height: height - 8)
            item.cornerRadius = 11
            item.backgroundColor = entry.isCurrent ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor : CGColor(gray: 1, alpha: 0.08)
            let text = CATextLayer()
            text.delegate = NoImplicitAnimations.shared
            text.string = entry.label
            text.font = font
            text.fontSize = 12
            text.foregroundColor = CGColor(gray: 1, alpha: entry.isCurrent ? 1 : 0.85)
            text.contentsScale = scale
            text.frame = CGRect(x: 12, y: 3, width: textWidth + 2, height: 16)
            item.addSublayer(text)
            var iconX = 12 + textWidth + 8
            for app in icons {
                let icon = CALayer()
                icon.delegate = NoImplicitAnimations.shared
                icon.frame = CGRect(x: iconX, y: 3, width: iconSize, height: iconSize)
                icon.contents = app.icon
                icon.contentsGravity = .resizeAspect
                item.addSublayer(icon)
                iconX += iconSize + 4
            }
            layer?.addSublayer(item)
            items.append(item)
            itemFrames.append(item.frame)
            _ = index
            x += width + 6
        }
        let size = CGSize(width: max(60, x), height: height)
        frame = CGRect(origin: .zero, size: size)
        backdrop.frame = bounds
        return size
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = itemFrames.firstIndex(where: { $0.contains(point) }) { onSelect?(index) }
    }
}
