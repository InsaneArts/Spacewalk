import Foundation

public struct Space: Equatable, Sendable {
    public let id: UInt64
    /// 0 = user desktop, 4 = a fullscreen app's space.
    public let type: Int
    public let uuid: String
    public var isFullscreen: Bool { type == 4 }
    /// Key for a user-given name. The first Space of a display can report an empty uuid, so the
    /// managed id fills in there; config files keep the uuid where there is one.
    public var nameKey: String { uuid.isEmpty ? "id:\(id)" : uuid }
}

/// The ordered spaces of one display, as Mission Control shows them.
public struct DisplaySpaces: Equatable, Sendable {
    public let displayUUID: String
    public let spaces: [Space]
    public let currentID: UInt64

    public var currentIndex: Int? { spaces.firstIndex { $0.id == currentID } }
    public var count: Int { spaces.count }

    /// Human labels: a user name when one is set, else "Desktop 1", "Full screen 3" by list position.
    public func label(at index: Int, names: [String: String] = [:]) -> String {
        guard spaces.indices.contains(index) else { return "Space \(index + 1)" }
        let space = spaces[index]
        if let name = names[space.nameKey]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if space.isFullscreen { return "Full screen \(index + 1)" }
        let desktopNumber = spaces.prefix(index + 1).filter { !$0.isFullscreen }.count
        return "Desktop \(desktopNumber)"
    }
}

public struct SpaceSnapshot: Sendable {
    public let displays: [DisplaySpaces]

    public func display(uuid: String) -> DisplaySpaces? { displays.first { $0.displayUUID == uuid } }

    /// Parses the array returned by SLSCopyManagedDisplaySpaces. `activeSpace` fills in the current
    /// space for displays whose dictionary lacks one.
    public static func parse(_ raw: [[String: Any]], activeSpace: UInt64) -> SpaceSnapshot {
        let displays = raw.compactMap { dict -> DisplaySpaces? in
            guard let uuid = dict["Display Identifier"] as? String,
                  let list = dict["Spaces"] as? [[String: Any]] else { return nil }
            let spaces = list.compactMap { entry -> Space? in
                guard let id = (entry["id64"] as? NSNumber)?.uint64Value else { return nil }
                return Space(id: id, type: (entry["type"] as? NSNumber)?.intValue ?? 0, uuid: entry["uuid"] as? String ?? "")
            }
            let current = ((dict["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
            let currentID = current ?? (spaces.contains { $0.id == activeSpace } ? activeSpace : spaces.first?.id ?? 0)
            return DisplaySpaces(displayUUID: uuid, spaces: spaces, currentID: currentID)
        }
        return SpaceSnapshot(displays: displays)
    }
}
