import AppKit
import CoreGraphics

/// Synthesizes the trackpad "Dock swipe" gesture that switches Spaces. A swipe with near-zero
/// travel and a strong fling commits the switch with nothing left to animate, so the Dock changes
/// space instantly while still owning its own state. Posting events needs Accessibility.
///
/// Field numbers are undocumented CGEvent fields, first mapped by the InstantSpaceSwitcher and
/// noswoosh projects. macOS 27 also validates a serialized IOHID payload in field 4205 and expects
/// each DockControl event to be paired with a companion gesture event.
public enum DockSwipe {
    public enum Phase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

    public static let gestureEventType: Int64 = 29
    public static let dockControlEventType: Int64 = 30
    public static let dockSwipeHIDType: Int64 = 23
    public static let horizontalMotion: Int64 = 1
    /// Marks our own events so an event tap can let them through.
    public static let eventTag: Int64 = 0x474C_4445 // 'GLDE'
    static let rawPayloadTag = 4205

    public static func field(_ number: UInt32) -> CGEventField { unsafeBitCast(number, to: CGEventField.self) }
    static let eventTypeField = field(55)
    static let hidTypeField = field(110)
    static let swipeMaskField = field(115)
    static let motionField = field(123)
    static let progressField = field(124)
    static let positionXField = field(125)
    static let positionYField = field(126)
    static let velocityXField = field(129)
    static let velocityYField = field(130)
    static let phaseField = field(132)

    /// macOS 27 and later need the IOHID payload. `SPACEWALK_FORCE_AUGMENT=1/0` overrides for testing.
    public static var usesAugmentedEvents: Bool {
        if let force = ProcessInfo.processInfo.environment["SPACEWALK_FORCE_AUGMENT"] { return force == "1" }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    /// A real rightward swipe reports positive progress and velocity on every version.
    public static func isRightward(_ value: Double) -> Bool { value > 0 }

    /// On the 27 path the posted sign is relative to "Natural scrolling" being on.
    static var postedSign: Double {
        guard usesAugmentedEvents else { return 1 }
        let natural = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
        return natural ? 1 : -1
    }

    /// Posts `steps` complete swipes in `direction`. Returns false when an event could not be built.
    @discardableResult
    public static func post(_ direction: SwipeDirection, steps: Int = 1) -> Bool {
        let right = direction == .right
        for _ in 0..<max(1, steps) {
            if usesAugmentedEvents {
                var events: [CGEvent] = []
                for phase in [Phase.began, .changed, .ended] {
                    guard let dock = augmentedEvent(phase, right: right), let event = augment(dock) else { return false }
                    event.setIntegerValueField(.eventSourceUserData, value: eventTag)
                    events.append(event)
                }
                for event in events { postPair(event) }
            } else {
                for phase in [Phase.began, .changed, .ended] {
                    guard let event = plainEvent(phase, right: right) else { return false }
                    event.post(tap: .cgSessionEventTap)
                }
            }
        }
        return true
    }

    // MARK: macOS 26 path

    static func plainEvent(_ phase: Phase, right: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        // 1e-4, not the smallest float: subnormals flush to zero in the event pipeline and lose the sign.
        let progress = 1e-4 * (right ? 1.0 : -1.0)
        let velocity = 2000.0 * (right ? 1.0 : -1.0)
        event.setIntegerValueField(eventTypeField, value: dockControlEventType)
        event.setIntegerValueField(hidTypeField, value: dockSwipeHIDType)
        event.setIntegerValueField(phaseField, value: phase.rawValue)
        event.setDoubleValueField(progressField, value: progress)
        event.setIntegerValueField(motionField, value: horizontalMotion)
        event.setDoubleValueField(velocityXField, value: velocity)
        event.setDoubleValueField(velocityYField, value: velocity)
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        return event
    }

    // MARK: macOS 27 path

    static func augmentedEvent(_ phase: Phase, right: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let sign = postedSign
        event.setIntegerValueField(eventTypeField, value: dockControlEventType)
        event.setIntegerValueField(hidTypeField, value: dockSwipeHIDType)
        event.setIntegerValueField(phaseField, value: phase.rawValue)
        // Direction is inverted on this path: rightward = negative progress.
        event.setDoubleValueField(progressField, value: (right ? -1e-4 : 1e-4) * sign)
        event.setIntegerValueField(motionField, value: horizontalMotion)
        event.setDoubleValueField(positionXField, value: 0.1)
        if phase == .ended {
            event.setDoubleValueField(velocityXField, value: (right ? -9999.0 : 9999.0) * sign)
        }
        return event
    }

    /// Round-trips the event through its serialized form to append the payload the setters cannot write.
    static func augment(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data else { return nil }
        var bytes = [UInt8](data as Data)
        guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2 else { return nil }
        let payload = iohidPayload(phase: event.getIntegerValueField(phaseField),
                                   motion: event.getIntegerValueField(motionField),
                                   progress: event.getDoubleValueField(progressField),
                                   positionX: event.getDoubleValueField(positionXField),
                                   positionY: event.getDoubleValueField(positionYField),
                                   velocityX: event.getDoubleValueField(velocityXField),
                                   velocityY: event.getDoubleValueField(velocityYField),
                                   mask: event.getIntegerValueField(swipeMaskField),
                                   timestamp: event.timestamp)
        bytes.append(UInt8((payload.count >> 8) & 0xFF))
        bytes.append(UInt8(payload.count & 0xFF))
        bytes.append(UInt8((rawPayloadTag >> 8) & 0xFF))
        bytes.append(UInt8(rawPayloadTag & 0xFF))
        bytes.append(contentsOf: payload)
        return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
    }

    static func postPair(_ dock: CGEvent) {
        guard let companion = CGEvent(source: nil) else { return }
        companion.setIntegerValueField(.eventSourceUserData, value: eventTag)
        companion.setIntegerValueField(eventTypeField, value: gestureEventType)
        dock.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
    }

    /// 16.16 fixed point, never rounding a non-zero value to zero (the sign carries the direction).
    static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(truncatingIfNeeded: Int64(value * 65536.0))
        if fixed == 0 && value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }

    /// Queue header (28 bytes) + fluid touch gesture record (40) + velocity record (28) when needed.
    static func iohidPayload(phase: Int64, motion: Int64, progress: Double, positionX: Double, positionY: Double,
                             velocityX: Double, velocityY: Double, mask: Int64, timestamp: UInt64) -> [UInt8] {
        let includeVelocity = velocityX != 0 || velocityY != 0 || phase == Phase.ended.rawValue
        var bytes: [UInt8] = []
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        le(timestamp != 0 ? timestamp : mach_absolute_time())
        le(UInt64(0))                               // sender id
        le(UInt32(0))                               // options
        le(UInt32(0))                               // attribute length
        le(UInt32(includeVelocity ? 2 : 1))         // event count
        le(UInt32(40))                              // gesture record size
        le(UInt32(23))                              // fluid touch gesture
        le(UInt32((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24))
        bytes.append(contentsOf: [0, 0, 0, 0])      // depth + reserved
        le(fixed1616(positionX))
        le(fixed1616(positionY))
        le(Int32(0))                                // position z
        le(UInt32(truncatingIfNeeded: mask))
        le(UInt16(truncatingIfNeeded: motion))
        le(UInt16(3))                               // flavor: Dock primary
        le(fixed1616(progress))
        if includeVelocity {
            le(UInt32(28))
            le(UInt32(9))                           // velocity record
            le(UInt32(0))
            bytes.append(contentsOf: [1, 0, 0, 0])  // depth 1 + reserved
            le(fixed1616(velocityX))
            le(fixed1616(velocityY))
            le(Int32(0))
        }
        return bytes
    }
}
