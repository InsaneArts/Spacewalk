import Foundation

/// The few private SkyLight (WindowServer) calls Spacewalk needs for bookkeeping. Resolved at runtime
/// with dlsym so a missing symbol degrades to "unavailable" instead of a crash. These calls only
/// read state (and toggle two symbolic hotkeys); they work with System Integrity Protection on.
enum SkyLight {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias ManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetSymbolicHotKey = @convention(c) (Int32, Bool) -> Int32
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let mainConnection = symbol("SLSMainConnectionID", MainConnection.self)
    private static let activeSpaceFn = symbol("SLSGetActiveSpace", ActiveSpace.self)
    private static let managedDisplaySpacesFn = symbol("SLSCopyManagedDisplaySpaces", ManagedDisplaySpaces.self)
    private static let setSymbolicHotKeyFn = symbol("SLSSetSymbolicHotKeyEnabled", SetSymbolicHotKey.self)
    private static let spacesForWindowsFn = symbol("SLSCopySpacesForWindows", SpacesForWindows.self)

    static var isAvailable: Bool { mainConnection != nil && activeSpaceFn != nil && managedDisplaySpacesFn != nil }

    static let connection: Int32 = mainConnection?() ?? 0

    /// The space that has keyboard focus.
    static func activeSpace() -> UInt64 {
        activeSpaceFn?(connection) ?? 0
    }

    /// One dictionary per display: "Display Identifier", "Spaces" (id64, type, uuid), "Current Space".
    static func managedDisplaySpaces() -> [[String: Any]] {
        guard let raw = managedDisplaySpacesFn?(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return raw
    }

    /// The set of spaces the given windows live on.
    static func spaces(forWindows ids: [UInt32]) -> Set<UInt64> {
        guard !ids.isEmpty, let raw = spacesForWindowsFn?(connection, 0x7, ids as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(raw.map(\.uint64Value))
    }

    /// Symbolic hotkey 79 = move left a space (⌃←), 81 = move right a space (⌃→).
    @discardableResult
    static func setSymbolicHotKey(_ id: Int32, enabled: Bool) -> Bool {
        guard let setSymbolicHotKeyFn else { return false }
        return setSymbolicHotKeyFn(id, enabled) == 0
    }
}
