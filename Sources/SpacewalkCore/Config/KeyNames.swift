import Carbon.HIToolbox

/// AeroSpace-style key strings: `ctrl-alt-1`, `cmd-shift-right`, `f3`.
public enum KeyNames {
    static let codes: [(name: String, code: UInt32)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11),
        ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
        ("5", 23), ("equal", 24), ("9", 25), ("7", 26), ("minus", 27), ("8", 28), ("0", 29), ("rightSquareBracket", 30), ("o", 31),
        ("u", 32), ("leftSquareBracket", 33), ("i", 34), ("p", 35), ("enter", 36), ("l", 37), ("j", 38), ("quote", 39), ("k", 40),
        ("semicolon", 41), ("backslash", 42), ("comma", 43), ("slash", 44), ("n", 45), ("m", 46), ("period", 47), ("tab", 48),
        ("space", 49), ("backtick", 50), ("backspace", 51), ("esc", 53), ("keypadDecimalMark", 65), ("keypadMultiply", 67),
        ("keypadPlus", 69), ("keypadClear", 71), ("keypadDivide", 75), ("keypadEnter", 76), ("keypadMinus", 78), ("keypadEqual", 81),
        ("keypad0", 82), ("keypad1", 83), ("keypad2", 84), ("keypad3", 85), ("keypad4", 86), ("keypad5", 87), ("keypad6", 88),
        ("keypad7", 89), ("keypad8", 91), ("keypad9", 92), ("f17", 64), ("f18", 79), ("f19", 80), ("f20", 90), ("f5", 96), ("f6", 97),
        ("f7", 98), ("f3", 99), ("f8", 100), ("f9", 101), ("f11", 103), ("f13", 105), ("f16", 106), ("f14", 107), ("f10", 109),
        ("f12", 111), ("f15", 113), ("home", 115), ("pageUp", 116), ("forwardDelete", 117), ("f4", 118), ("end", 119), ("f2", 120),
        ("pageDown", 121), ("f1", 122), ("left", 123), ("right", 124), ("down", 125), ("up", 126),
    ]

    static let modifiers: [String: UInt32] = [
        "ctrl": UInt32(controlKey), "control": UInt32(controlKey),
        "alt": UInt32(optionKey), "opt": UInt32(optionKey), "option": UInt32(optionKey),
        "cmd": UInt32(cmdKey), "command": UInt32(cmdKey),
        "shift": UInt32(shiftKey),
    ]

    /// `ctrl-alt-1` → KeyCombo. Empty text means unbound. Unknown names return nil.
    public static func combo(from text: String) -> KeyCombo?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        let parts = trimmed.split(separator: "-").map { String($0) }
        guard let last = parts.last else { return nil }
        var flags: UInt32 = 0
        for part in parts.dropLast() {
            guard let flag = modifiers[part.lowercased()] else { return nil }
            flags |= flag
        }
        if let entry = codes.first(where: { $0.name.lowercased() == last.lowercased() }) {
            return .some(KeyCombo(keyCode: entry.code, modifiers: flags))
        }
        if last.lowercased().hasPrefix("key:"), let code = UInt32(last.dropFirst(4)) {
            return .some(KeyCombo(keyCode: code, modifiers: flags))
        }
        return nil
    }

    public static func text(for combo: KeyCombo?) -> String {
        guard let combo else { return "" }
        var parts: [String] = []
        if combo.modifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if combo.modifiers & UInt32(optionKey) != 0 { parts.append("alt") }
        if combo.modifiers & UInt32(cmdKey) != 0 { parts.append("cmd") }
        if combo.modifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        parts.append(codes.first { $0.code == combo.keyCode }?.name ?? "key:\(combo.keyCode)")
        return parts.joined(separator: "-")
    }
}
