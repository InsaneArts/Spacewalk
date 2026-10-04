import AppKit
import CoreGraphics

public enum GestureEvent: Sendable {
    case began
    /// Signed progress as the Dock reports it: positive means towards the next space. About 0.6 to 1.2 for a full swipe.
    case changed(progress: Double)
    case ended(progress: Double, velocity: Double)
    case cancelled
    /// Vertical swipes, the Mission Control gesture, when the overview replaces it.
    case overviewBegan
    case overviewChanged(progress: Double)
    case overviewEnded(progress: Double, velocity: Double)
}

/// Replaces real three-finger horizontal Dock swipes with Spacewalk switches. Needs Accessibility.
@MainActor
public final class SwipeInterceptor {
    /// Fired once per swipe when `interactive` is off.
    public var onSwipe: ((SwipeDirection) -> Void)?
    /// Streams the whole gesture when `interactive` is on, so the transition can follow the fingers.
    public var onGesture: ((GestureEvent) -> Void)?
    public var interactive = false
    /// Take the vertical Dock swipe too and drive the overview with it.
    public var overviewGestures = false
    private var verticalTracking = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracking = false
    private var fired = false

    public init() {}

    public var isActive: Bool { tap != nil }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << UInt64(DockSwipe.gestureEventType)) | (1 << UInt64(DockSwipe.dockControlEventType))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<SwipeInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
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
        tracking = false
        fired = false
    }

    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return Unmanaged.passUnretained(event)
        }
        // Our own synthetic swipes carry a tag; let them through untouched.
        if event.getIntegerValueField(.eventSourceUserData) == DockSwipe.eventTag { return Unmanaged.passUnretained(event) }
        let kind = event.getIntegerValueField(DockSwipe.field(55))
        if kind == DockSwipe.dockControlEventType {
            guard event.getIntegerValueField(DockSwipe.field(110)) == DockSwipe.dockSwipeHIDType else { return Unmanaged.passUnretained(event) }
            let motion = event.getIntegerValueField(DockSwipe.field(123))
            let phase = event.getIntegerValueField(DockSwipe.field(132))
            if motion == DockSwipe.horizontalMotion {
                return MainActor.assumeIsolated { self.handleDockSwipe(phase: phase, event: event) }
            }
            return MainActor.assumeIsolated { self.handleVerticalSwipe(phase: phase, event: event) }
        }
        if kind == DockSwipe.gestureEventType {
            let swallow = MainActor.assumeIsolated { self.tracking || self.verticalTracking }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleVerticalSwipe(phase: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard overviewGestures else { return Unmanaged.passUnretained(event) }
        let progress = event.getDoubleValueField(DockSwipe.field(124))
        let velocity = event.getDoubleValueField(DockSwipe.field(130))
        switch phase {
        case DockSwipe.Phase.began.rawValue:
            verticalTracking = true
            onGesture?(.overviewBegan)
        case DockSwipe.Phase.changed.rawValue:
            guard verticalTracking else { return Unmanaged.passUnretained(event) }
            onGesture?(.overviewChanged(progress: progress))
        case DockSwipe.Phase.ended.rawValue, DockSwipe.Phase.cancelled.rawValue:
            guard verticalTracking else { return Unmanaged.passUnretained(event) }
            verticalTracking = false
            onGesture?(.overviewEnded(progress: progress, velocity: velocity))
        default:
            return verticalTracking ? nil : Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func handleDockSwipe(phase: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        if interactive {
            let progress = event.getDoubleValueField(DockSwipe.field(124))
            let velocity = event.getDoubleValueField(DockSwipe.field(129))
            switch phase {
            case DockSwipe.Phase.began.rawValue:
                tracking = true
                onGesture?(.began)
            case DockSwipe.Phase.changed.rawValue:
                guard tracking else { return Unmanaged.passUnretained(event) }
                onGesture?(.changed(progress: progress))
            case DockSwipe.Phase.ended.rawValue:
                guard tracking else { return Unmanaged.passUnretained(event) }
                tracking = false
                onGesture?(.ended(progress: progress, velocity: velocity))
            case DockSwipe.Phase.cancelled.rawValue:
                tracking = false
                onGesture?(.cancelled)
            default:
                return tracking ? nil : Unmanaged.passUnretained(event)
            }
            return nil
        }
        switch phase {
        case DockSwipe.Phase.began.rawValue:
            tracking = true
            fired = false
            return nil
        case DockSwipe.Phase.changed.rawValue:
            guard tracking else { return Unmanaged.passUnretained(event) }
            if !fired {
                let progress = event.getDoubleValueField(DockSwipe.field(124))
                if progress != 0 {
                    fired = true
                    onSwipe?(DockSwipe.isRightward(progress) ? .right : .left)
                }
            }
            return nil
        case DockSwipe.Phase.ended.rawValue:
            guard tracking else { return Unmanaged.passUnretained(event) }
            if !fired {
                let velocity = event.getDoubleValueField(DockSwipe.field(129))
                if velocity != 0 { onSwipe?(DockSwipe.isRightward(velocity) ? .right : .left) }
            }
            tracking = false
            fired = false
            return nil
        case DockSwipe.Phase.cancelled.rawValue:
            tracking = false
            fired = false
            return nil
        default:
            return tracking ? nil : Unmanaged.passUnretained(event)
        }
    }
}
