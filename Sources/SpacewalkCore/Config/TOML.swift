import Foundation

/// The subset of TOML the config file uses: comments, tables, dotted and quoted keys, strings,
/// integers, floats, booleans, arrays and inline tables. No dependency, about 200 lines.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var table: [String: TOMLValue]? { if case .table(let t) = self { return t } else { return nil } }
}

public struct TOMLError: Error, LocalizedError {
    public let line: Int
    public let message: String
    public var errorDescription: String? { "line \(line): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var current: [String] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let number = index + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw TOMLError(line: number, message: "table header is missing ']'") }
                let inner = String(line.dropFirst().dropLast())
                guard !inner.hasPrefix("[") else { throw TOMLError(line: number, message: "arrays of tables are not supported") }
                current = try keyPath(inner, line: number)
                root = set(root, path: current, value: .table(lookup(root, path: current)?.table ?? [:]))
                continue
            }
            var scanner = Scanner(line, line: number)
            let key = try scanner.key()
            scanner.skipSpaces()
            guard scanner.take("=") else { throw TOMLError(line: number, message: "expected '=' after key") }
            scanner.skipSpaces()
            let value = try scanner.value()
            scanner.skipSpaces()
            guard scanner.atEnd else { throw TOMLError(line: number, message: "unexpected text after value") }
            root = set(root, path: current + key, value: value)
        }
        return root
    }

    /// Looks a dotted path up, e.g. ["transition", "effect"].
    public static func lookup(_ table: [String: TOMLValue], path: [String]) -> TOMLValue? {
        guard let first = path.first else { return nil }
        guard let value = table[first] else { return nil }
        if path.count == 1 { return value }
        guard let nested = value.table else { return nil }
        return lookup(nested, path: Array(path.dropFirst()))
    }

    static func set(_ table: [String: TOMLValue], path: [String], value: TOMLValue) -> [String: TOMLValue] {
        var copy = table
        guard let first = path.first else { return copy }
        if path.count == 1 {
            copy[first] = value
        } else {
            let nested = copy[first]?.table ?? [:]
            copy[first] = .table(set(nested, path: Array(path.dropFirst()), value: value))
        }
        return copy
    }

    static func stripComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if let open = quote {
                result.append(character)
                if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil }
                continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" { quote = character }
            result.append(character)
        }
        return result
    }

    static func keyPath(_ text: String, line: Int) throws -> [String] {
        var scanner = Scanner(text, line: line)
        let path = try scanner.key()
        scanner.skipSpaces()
        guard scanner.atEnd else { throw TOMLError(line: line, message: "bad key '\(text)'") }
        return path
    }

    /// Quotes a string for writing.
    public static func quote(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 { out += String(format: "\\u%04X", character.value) } else { out.unicodeScalars.append(character) }
            }
        }
        return out + "\""
    }

    struct Scanner {
        let chars: [Character]
        var index = 0
        let line: Int

        init(_ text: String, line: Int) {
            chars = Array(text)
            self.line = line
        }

        var atEnd: Bool { index >= chars.count }
        var peek: Character? { atEnd ? nil : chars[index] }

        mutating func skipSpaces() { while let c = peek, c == " " || c == "\t" { index += 1 } }

        mutating func take(_ character: Character) -> Bool {
            guard peek == character else { return false }
            index += 1
            return true
        }

        mutating func key() throws -> [String] {
            var path: [String] = []
            while true {
                skipSpaces()
                if peek == "\"" {
                    path.append(try basicString())
                } else if peek == "'" {
                    path.append(try literalString())
                } else {
                    var bare = ""
                    while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" { bare.append(c); index += 1 }
                    guard !bare.isEmpty else { throw TOMLError(line: line, message: "expected a key") }
                    path.append(bare)
                }
                skipSpaces()
                if take(".") { continue }
                return path
            }
        }

        mutating func value() throws -> TOMLValue {
            guard let c = peek else { throw TOMLError(line: line, message: "expected a value") }
            switch c {
            case "\"": return .string(try basicString())
            case "'": return .string(try literalString())
            case "[":
                index += 1
                var items: [TOMLValue] = []
                while true {
                    skipSpaces()
                    if take("]") { return .array(items) }
                    items.append(try value())
                    skipSpaces()
                    if take(",") { continue }
                    guard take("]") else { throw TOMLError(line: line, message: "expected ',' or ']' in array") }
                    return .array(items)
                }
            case "{":
                index += 1
                var table: [String: TOMLValue] = [:]
                while true {
                    skipSpaces()
                    if take("}") { return .table(table) }
                    let path = try key()
                    skipSpaces()
                    guard take("=") else { throw TOMLError(line: line, message: "expected '=' in inline table") }
                    skipSpaces()
                    table = TOML.set(table, path: path, value: try value())
                    skipSpaces()
                    if take(",") { continue }
                    guard take("}") else { throw TOMLError(line: line, message: "expected ',' or '}' in inline table") }
                    return .table(table)
                }
            default:
                var word = ""
                while let c = peek, !(c == "," || c == "]" || c == "}" || c == " " || c == "\t") { word.append(c); index += 1 }
                if word == "true" { return .bool(true) }
                if word == "false" { return .bool(false) }
                let number = word.replacingOccurrences(of: "_", with: "")
                if let i = Int(number) { return .int(i) }
                if let d = Double(number) { return .double(d) }
                throw TOMLError(line: line, message: "unrecognised value '\(word)'")
            }
        }

        mutating func basicString() throws -> String {
            guard take("\"") else { throw TOMLError(line: line, message: "expected '\"'") }
            var out = ""
            while let c = peek {
                index += 1
                if c == "\"" { return out }
                if c == "\\" {
                    guard let e = peek else { break }
                    index += 1
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "u":
                        let hex = String(chars[index..<min(index + 4, chars.count)])
                        index += 4
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
                    default: out.append(e)
                    }
                    continue
                }
                out.append(c)
            }
            throw TOMLError(line: line, message: "unterminated string")
        }

        mutating func literalString() throws -> String {
            guard take("'") else { throw TOMLError(line: line, message: "expected '''") }
            var out = ""
            while let c = peek {
                index += 1
                if c == "'" { return out }
                out.append(c)
            }
            throw TOMLError(line: line, message: "unterminated string")
        }
    }
}
