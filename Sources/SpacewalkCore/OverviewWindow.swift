import AppKit

public struct OverviewEntry {
    public let label: String
    public let wallpaper: IOSurface?
    public let windows: IOSurface?
    public let isCurrent: Bool
    public let apps: [SpaceEngine.AppBadge]
    public init(label: String, wallpaper: IOSurface?, windows: IOSurface?, isCurrent: Bool, apps: [SpaceEngine.AppBadge]) {
        self.label = label
        self.wallpaper = wallpaper
        self.windows = windows
        self.isCurrent = isCurrent
        self.apps = apps
    }
}

/// All Spaces as large real pictures over a blurred screen, niri style: the current Space zooms out
/// into its card, the one you pick zooms back to fill the screen. Arrows, digits, typing a Space or
/// app name, click, or the gesture that opened it.
@MainActor
public final class OverviewWindow {
    /// Fired when the chosen card fills the screen. The receiver takes over the picture and hides this window.
    public var onSelect: ((Int) -> Void)?
    public var onCancel: (() -> Void)?

    private let panel: OverviewPanel
    private let content: OverviewView
    private var screen: NSScreen

    public init(screen: NSScreen) {
        self.screen = screen
        panel = OverviewPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 4)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        content = OverviewView(frame: NSRect(origin: .zero, size: screen.frame.size))
        panel.contentView = content
        content.onSelect = { [weak self] index in self?.onSelect?(index) }
        content.onCancel = { [weak self] in self?.hide(); self?.onCancel?() }
    }

    public var isVisible: Bool { panel.isVisible }
    public var isScrubbing: Bool { content.scrubbing }

    public func update(screen: NSScreen) {
        self.screen = screen
        panel.setFrame(screen.frame, display: false)
        content.frame = NSRect(origin: .zero, size: screen.frame.size)
    }

    /// Opens with the zoom-out animation.
    public func show(entries: [OverviewEntry], current: Int, columns: Int) {
        present(entries: entries, current: current, columns: columns)
        content.open(animated: true)
    }

    /// Opens frozen at progress 0, for a gesture to drive.
    public func beginScrub(entries: [OverviewEntry], current: Int, columns: Int) {
        present(entries: entries, current: current, columns: columns)
        content.open(animated: false)
    }

    public func scrub(_ progress: Double) { content.scrub(progress) }

    /// Finishes a gesture: settle open, or zoom back and hide.
    public func endScrub(open: Bool) {
        if open {
            content.settleOpen()
        } else {
            content.zoomBack { [weak self] in self?.hide(); self?.onCancel?() }
        }
    }

    public func hide() {
        panel.orderOut(nil)
        content.clear()
    }

    private func present(entries: [OverviewEntry], current: Int, columns: Int) {
        content.populate(entries: entries, current: current, columns: columns, scale: screen.backingScaleFactor)
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content)
    }
}

final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The blurred backdrop plus one card per Space, with the zoom animations.
final class OverviewView: NSView {
    var onSelect: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var scrubbing = false

    private let backdrop = NSVisualEffectView()
    private let canvas = NSView()
    private var cards: [CALayer] = []
    private var shadows: [CALayer] = []
    private var labels: [CATextLayer] = []
    private var badgeRows: [CALayer] = []
    private var slots: [CGRect] = []
    private var searchText: [String] = []
    private var current = 0
    private var selected = 0
    private var typed = ""
    private var typedAt: TimeInterval = 0
    private var closing = false
    private let openDuration = 0.32

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        backdrop.wantsLayer = true
        addSubview(backdrop)
        canvas.wantsLayer = true
        canvas.autoresizingMask = [.width, .height]
        canvas.frame = bounds
        canvas.layer?.delegate = NoImplicitAnimations.shared
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    private var timedLayers: [CALayer] { [canvas.layer, backdrop.layer].compactMap { $0 } }

    func clear() {
        for layer in cards + shadows + labels + badgeRows { layer.removeFromSuperlayer() }
        cards.removeAll(); shadows.removeAll(); labels.removeAll(); badgeRows.removeAll(); slots.removeAll(); searchText.removeAll()
        typed = ""
        closing = false
        scrubbing = false
        for layer in timedLayers { layer.removeAllAnimations(); layer.speed = 1; layer.timeOffset = 0 }
        backdrop.layer?.opacity = 1
    }

    // MARK: Layout

    func populate(entries: [OverviewEntry], current: Int, columns: Int, scale: CGFloat) {
        clear()
        self.current = min(max(0, current), max(0, entries.count - 1))
        selected = self.current
        searchText = entries.map { ($0.label + " " + $0.apps.map(\.name).joined(separator: " ")).lowercased() }
        let count = entries.count
        guard count > 0 else { return }
        let cols = columns > 0 ? min(columns, count) : min(count, 5)
        let rows = Int(ceil(Double(count) / Double(cols)))
        let gap: CGFloat = 28
        let labelHeight: CGFloat = 36
        let availableWidth = bounds.width - 120
        let availableHeight = bounds.height - 140
        let aspect = bounds.width / max(1, bounds.height)
        var cardWidth = min(availableWidth * 0.42, (availableWidth - gap * CGFloat(cols - 1)) / CGFloat(cols))
        var cardHeight = cardWidth / aspect
        if (cardHeight + labelHeight) * CGFloat(rows) + gap * CGFloat(rows - 1) > availableHeight {
            cardHeight = (availableHeight - gap * CGFloat(rows - 1)) / CGFloat(rows) - labelHeight
            cardWidth = cardHeight * aspect
        }
        let gridWidth = cardWidth * CGFloat(cols) + gap * CGFloat(cols - 1)
        let gridHeight = (cardHeight + labelHeight) * CGFloat(rows) + gap * CGFloat(rows - 1)
        let originX = (bounds.width - gridWidth) / 2
        let top = (bounds.height + gridHeight) / 2

        for (index, entry) in entries.enumerated() {
            let column = index % cols
            let row = index / cols
            let slot = CGRect(x: originX + CGFloat(column) * (cardWidth + gap),
                              y: top - CGFloat(row + 1) * (cardHeight + labelHeight) - CGFloat(row) * gap + labelHeight,
                              width: cardWidth, height: cardHeight)
            slots.append(slot)

            let shadow = CALayer()
            shadow.delegate = NoImplicitAnimations.shared
            shadow.frame = slot
            shadow.shadowColor = CGColor(gray: 0, alpha: 1)
            shadow.shadowOpacity = 0.5
            shadow.shadowRadius = 24
            shadow.shadowOffset = CGSize(width: 0, height: -8)
            shadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: slot.size), cornerWidth: 14, cornerHeight: 14, transform: nil)
            canvas.layer?.addSublayer(shadow)
            shadows.append(shadow)

            let card = CALayer()
            card.delegate = NoImplicitAnimations.shared
            card.frame = slot
            card.cornerRadius = 14
            card.masksToBounds = true
            card.backgroundColor = CGColor(gray: 0.15, alpha: 1)
            card.borderColor = NSColor.controlAccentColor.cgColor
            for (contents, keep) in [(entry.wallpaper as AnyObject?, true), (entry.windows as AnyObject?, false)] {
                guard contents != nil || keep else { continue }
                let picture = CALayer()
                picture.delegate = NoImplicitAnimations.shared
                picture.frame = CGRect(origin: .zero, size: slot.size)
                picture.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                picture.contents = contents
                picture.contentsGravity = .resize
                picture.minificationFilter = .linear
                card.addSublayer(picture)
            }
            canvas.layer?.addSublayer(card)
            cards.append(card)

            let badges = CALayer()
            badges.delegate = NoImplicitAnimations.shared
            let iconSize: CGFloat = 26
            let shown = Array(entry.apps.prefix(7))
            var x: CGFloat = 0
            for app in shown {
                let icon = CALayer()
                icon.delegate = NoImplicitAnimations.shared
                icon.frame = CGRect(x: x, y: 0, width: iconSize, height: iconSize)
                icon.contents = app.icon
                icon.contentsGravity = .resizeAspect
                icon.shadowColor = CGColor(gray: 0, alpha: 1)
                icon.shadowOpacity = 0.5
                icon.shadowRadius = 3
                icon.shadowOffset = CGSize(width: 0, height: -1)
                badges.addSublayer(icon)
                x += iconSize + 6
            }
            if entry.apps.count > shown.count {
                let more = CATextLayer()
                more.delegate = NoImplicitAnimations.shared
                more.string = "+\(entry.apps.count - shown.count)"
                more.fontSize = 12
                more.foregroundColor = CGColor(gray: 1, alpha: 0.9)
                more.contentsScale = scale
                more.frame = CGRect(x: x, y: 5, width: 36, height: 16)
                badges.addSublayer(more)
                x += 36
            }
            badges.frame = CGRect(x: slot.minX + 14, y: slot.minY + 12, width: max(1, x), height: iconSize)
            canvas.layer?.addSublayer(badges)
            badgeRows.append(badges)

            let text = CATextLayer()
            text.delegate = NoImplicitAnimations.shared
            text.string = entry.isCurrent ? "● \(entry.label)" : entry.label
            text.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            text.fontSize = 15
            text.foregroundColor = CGColor(gray: 1, alpha: 0.92)
            text.alignmentMode = .center
            text.contentsScale = scale
            text.frame = CGRect(x: slot.minX, y: slot.minY - labelHeight + 8, width: slot.width, height: 22)
            canvas.layer?.addSublayer(text)
            labels.append(text)
        }
        highlight()
    }

    // MARK: Opening and closing

    /// The current card starts as the whole screen and shrinks into its slot while the rest fades in.
    func open(animated: Bool) {
        guard cards.indices.contains(current) else { return }
        let timing = AnimationTiming(duration: openDuration, easing: .smooth, bounce: 0)
        var animations: [(CALayer, CAAnimation, String)] = []
        let full = CGRect(origin: .zero, size: bounds.size)
        let currentCard = cards[current]
        currentCard.zPosition = 10
        currentCard.borderWidth = 0
        animations.append((currentCard, timing.animation(keyPath: "bounds", from: NSValue(rect: full), to: NSValue(rect: CGRect(origin: .zero, size: slots[current].size))), "bounds"))
        animations.append((currentCard, timing.animation(keyPath: "position", from: NSValue(point: CGPoint(x: full.midX, y: full.midY)), to: NSValue(point: CGPoint(x: slots[current].midX, y: slots[current].midY))), "position"))
        animations.append((currentCard, timing.animation(keyPath: "cornerRadius", from: 0, to: 14), "cornerRadius"))
        for (index, card) in cards.enumerated() where index != current {
            let away: CGFloat = slots[index].midX < slots[current].midX ? -60 : 60
            animations.append((card, timing.animation(keyPath: "transform.translation.x", from: away, to: 0), "transform.translation.x"))
            animations.append((card, timing.animation(keyPath: "opacity", from: 0, to: 1), "opacity"))
            animations.append((shadows[index], timing.animation(keyPath: "opacity", from: 0, to: 1), "opacity"))
        }
        animations.append((shadows[current], timing.animation(keyPath: "opacity", from: 0, to: 1), "opacity"))
        for layer in labels + badgeRows { animations.append((layer, timing.animation(keyPath: "opacity", from: 0, to: 1), "opacity")) }
        if let layer = backdrop.layer { animations.append((layer, timing.animation(keyPath: "opacity", from: 0, to: 1), "opacity")) }

        scrubbing = !animated
        for layer in timedLayers {
            layer.speed = animated ? 1 : 0
            layer.timeOffset = 0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, animated, !self.closing else { return }
            self.cards[self.current].zPosition = 0
            for layer in self.cards + self.shadows + self.labels + self.badgeRows { layer.removeAllAnimations() }
            self.backdrop.layer?.removeAllAnimations()
            self.highlight()
        }
        for (layer, animation, key) in animations { layer.add(animation, forKey: key) }
        CATransaction.commit()
    }

    func scrub(_ progress: Double) {
        guard scrubbing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in timedLayers { layer.timeOffset = min(1, max(0, progress)) * openDuration }
        CATransaction.commit()
    }

    /// Lets a frozen opening run to completion from where the finger left it.
    func settleOpen() {
        guard scrubbing else { return }
        scrubbing = false
        for layer in timedLayers {
            let offset = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - offset
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + openDuration + 0.05) { [weak self] in
            guard let self, !self.closing else { return }
            for layer in self.timedLayers { layer.beginTime = 0 }
            self.cards[self.current].zPosition = 0
            for layer in self.cards + self.shadows + self.labels + self.badgeRows { layer.removeAllAnimations() }
            self.backdrop.layer?.removeAllAnimations()
            self.highlight()
        }
    }

    /// Zooms the current card back to full screen and hides. Used by cancel.
    func zoomBack(completion: @escaping () -> Void) {
        zoom(into: current, completion: completion)
    }

    /// The chosen card grows to fill the screen while everything else fades away.
    private func zoom(into index: Int, completion: @escaping () -> Void) {
        guard cards.indices.contains(index), !closing else { return }
        closing = true
        scrubbing = false
        for layer in timedLayers { layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0 }
        let timing = AnimationTiming(duration: 0.28, easing: .smooth, bounce: 0)
        let full = CGRect(origin: .zero, size: bounds.size)
        let card = cards[index]
        card.zPosition = 20
        let startBounds = card.presentation()?.bounds ?? card.bounds
        let startPosition = card.presentation()?.position ?? card.position
        var animations: [(CALayer, CAAnimation, String)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.borderWidth = 0
        card.transform = CATransform3DIdentity
        card.bounds = CGRect(origin: .zero, size: full.size)
        card.position = CGPoint(x: full.midX, y: full.midY)
        card.cornerRadius = 0
        CATransaction.commit()
        animations.append((card, timing.animation(keyPath: "bounds", from: NSValue(rect: startBounds), to: NSValue(rect: CGRect(origin: .zero, size: full.size))), "bounds"))
        animations.append((card, timing.animation(keyPath: "position", from: NSValue(point: startPosition), to: NSValue(point: CGPoint(x: full.midX, y: full.midY))), "position"))
        animations.append((card, timing.animation(keyPath: "cornerRadius", from: 14, to: 0), "cornerRadius"))
        for (other, layer) in cards.enumerated() where other != index {
            animations.append((layer, timing.animation(keyPath: "opacity", from: layer.presentation()?.opacity ?? 1, to: 0), "opacity"))
        }
        for layer in shadows + labels + badgeRows {
            animations.append((layer, timing.animation(keyPath: "opacity", from: layer.presentation()?.opacity ?? 1, to: 0), "opacity"))
        }
        if let layer = backdrop.layer { animations.append((layer, timing.animation(keyPath: "opacity", from: layer.presentation()?.opacity ?? 1, to: 0), "opacity")) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { completion() }
        for (layer, animation, key) in animations { layer.add(animation, forKey: key) }
        CATransaction.commit()
    }

    private func choose(_ index: Int) {
        selected = index
        highlight()
        zoom(into: index) { [weak self] in
            guard let self else { return }
            if index == self.current { self.onCancel?() } else { self.onSelect?(index) }
        }
    }

    // MARK: Selection

    private func highlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, card) in cards.enumerated() {
            let chosen = index == selected && !closing
            card.borderWidth = chosen ? 4 : 0
            card.transform = chosen && !scrubbing ? CATransform3DMakeScale(1.04, 1.04, 1) : CATransform3DIdentity
        }
        CATransaction.commit()
    }

    private func move(by delta: Int) {
        guard !cards.isEmpty, !closing else { return }
        selected = min(cards.count - 1, max(0, selected + delta))
        highlight()
    }

    private var cardsPerRow: Int {
        guard slots.count > 1 else { return 1 }
        let firstY = slots[0].minY
        return slots.filter { abs($0.minY - firstY) < 1 }.count
    }

    override func keyDown(with event: NSEvent) {
        guard !closing else { return }
        let columns = max(1, cardsPerRow)
        switch event.keyCode {
        case 53: choose(current)
        case 36, 76, 49: choose(selected)
        case 123: move(by: -1)
        case 124: move(by: 1)
        case 126: move(by: -columns)
        case 125: move(by: columns)
        case 48: move(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        default:
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return }
            if let digit = Int(characters), digit >= 1, digit <= cards.count {
                choose(digit - 1)
                return
            }
            let now = Date().timeIntervalSinceReferenceDate
            if now - typedAt > 1 { typed = "" }
            typedAt = now
            typed += characters.lowercased()
            if let match = searchText.firstIndex(where: { text in text.split(separator: " ").contains { $0.hasPrefix(typed) } }) {
                selected = match
                highlight()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !closing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = slots.firstIndex(where: { $0.contains(point) }) {
            choose(index)
        } else {
            choose(current)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !closing, abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 8 else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        move(by: delta < 0 ? 1 : -1)
    }
}
