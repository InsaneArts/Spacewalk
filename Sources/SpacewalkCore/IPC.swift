import Foundation

/// How the `spacewalk` CLI talks to the app: one distributed notification per command.
public enum SpacewalkIPC {
    public static let commandNotification = Notification.Name("dev.tgomareli.spacewalk.command")
    public static let targetKey = "target"
    public static let commandKey = "command"

    public static func sendCommand(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(commandNotification, object: nil,
                                                                     userInfo: [commandKey: command], deliverImmediately: true)
    }

    public static var pidFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spacewalk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spacewalk.pid")
    }

    public static var statusFile: URL {
        pidFile.deletingLastPathComponent().appendingPathComponent("status.json")
    }

    public static func writePIDFile() {
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    public static func removePIDFile() {
        try? FileManager.default.removeItem(at: pidFile)
    }

    public static var appIsRunning: Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    public static func encode(_ target: SpaceTarget) -> String? {
        (try? JSONEncoder().encode(target)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ text: String) -> SpaceTarget? {
        text.data(using: .utf8).flatMap { try? JSONDecoder().decode(SpaceTarget.self, from: $0) }
    }

    public static func send(_ target: SpaceTarget) {
        guard let payload = encode(target) else { return }
        DistributedNotificationCenter.default().postNotificationName(commandNotification, object: nil,
                                                                     userInfo: [targetKey: payload], deliverImmediately: true)
    }

    /// Parses CLI words: `switch 3`, `next`, `prev`, `back-and-forth`.
    public static func parseTarget(_ words: [String]) -> SpaceTarget? {
        switch words.first {
        case "switch", "space", "go":
            guard words.count > 1, let number = Int(words[1]), number >= 1 else { return nil }
            return .index(number)
        case "next": return .next
        case "prev", "previous": return .previous
        case "back-and-forth", "back": return .backAndForth
        default:
            return nil
        }
    }
}
