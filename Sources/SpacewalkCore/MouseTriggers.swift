import AppKit
import CoreGraphics

/// Mouse ways to switch: side buttons, and scrolling with the pointer against the top edge.
@MainActor
public final class MouseTriggers {
    public var onSwitch: ((SwipeDirection) -> Void)?
    public var buttonsEnabled = false
    public var edgeScrollEnabled = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var accumulated: Double = 0
    private var lastFired: Double = 0

    public init() {}

    public var isActive: Bool { tap != nil }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let triggers = Unmanaged<MouseTriggers>.fromOpaque(refcon).takeUnretainedValue()
            return triggers.handle(type: type, event: event)
        }, userInfo: refcon) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        }
        tap = nil
        source = nil
    }

    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return Unmanaged.passUnretained(event)
        }
        return MainActor.assumeIsolated { self.handleOnMain(type: type, event: event) }
    }

    private func handleOnMain(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = CACurrentMediaTime()
        switch type {
        case .otherMouseDown:
            guard buttonsEnabled else { return Unmanaged.passUnretained(event) }
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard button == 3 || button == 4, now - lastFired > 0.25 else { return Unmanaged.passUnretained(event) }
            lastFired = now
            onSwitch?(button == 3 ? .left : .right)
            return nil
        case .scrollWheel:
            guard edgeScrollEnabled else { return Unmanaged.passUnretained(event) }
            let location = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }),
                  location.y >= screen.frame.maxY - 2 else {
                accumulated = 0
                return Unmanaged.passUnretained(event)
            }
            let horizontal = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let vertical = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            accumulated += abs(horizontal) > abs(vertical) ? horizontal : -vertical
            if now - lastFired < 0.35 { accumulated = 0; return nil }
            if abs(accumulated) >= 30 {
                lastFired = now
                let direction: SwipeDirection = accumulated > 0 ? .right : .left
                accumulated = 0
                onSwitch?(direction)
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
