import AppKit

/// A borderless panel that covers one screen at window level 2: above app windows,
/// below floating panels, the Dock and the menu bar. Those stay live during a transition.
@MainActor
public final class OverlayWindow {
    public let panel: NSPanel
    public let stage: TransitionStage
    private let host: NSView

    public init(screen: NSScreen) {
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.title = "Spacewalk Overlay"

        host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        host.layerUsesCoreImageFilters = true
        host.layer?.masksToBounds = true
        stage = TransitionStage(size: screen.frame.size)
        host.layer?.addSublayer(stage.root)
        panel.contentView = host
        panel.setFrame(screen.frame, display: false)
    }

    public func update(screen: NSScreen) {
        panel.setFrame(screen.frame, display: false)
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        stage.size = screen.frame.size
    }

    public var windowID: CGWindowID { CGWindowID(panel.windowNumber) }
    public var isVisible: Bool { panel.isVisible }

    public func show() {
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
        stage.clear()
    }
}
