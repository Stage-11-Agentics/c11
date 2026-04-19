import Foundation

public typealias TomlTable = [String: TomlValue]

public enum TomlValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case table(TomlTable)
    case null

    public var tableValue: TomlTable? {
        guard case let .table(value) = self else { return nil }
        return value
    }
}

public enum TomlParseErrorKind: String, Equatable, Sendable {
    case syntax
    case unsupportedFeature
    case duplicateKey
    case invalidValue
    case unterminatedString
}

public struct TomlParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let column: Int
    public let kind: TomlParseErrorKind
    public let message: String
    public let expectedTokens: [String]
    public let foundToken: String?

    public var description: String {
        let expectedHint = expectedTokens.isEmpty
            ? ""
            : " expected \(expectedTokens.joined(separator: " or "))"
        let foundHint = foundToken.map { " saw \($0)" } ?? ""
        return "\(file):\(line):\(column): \(message)\(expectedHint)\(foundHint)"
    }
}

public struct TomlSubsetParser {
    public let file: String
    public let source: String

    public init(file: String = "<memory>", source: String) {
        self.file = file
        self.source = source
    }

    public static func parse(file: String = "<memory>", source: String) throws -> TomlTable {
        try TomlSubsetParser(file: file, source: source).parse()
    }

    public func parse() throws -> TomlTable {
        var parser = Parser(file: file, source: source)
        return try parser.parse()
    }
}

private struct SourceLocation {
    let file: String
    let line: Int
    let column: Int
}

private struct Scanner {
    private let source: String
    private var index: String.Index
    private(set) var line: Int = 1
    private(set) var column: Int = 1
    private let file: String

    init(file: String, source: String) {
        self.file = file
        self.source = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        self.index = self.source.startIndex
    }

    var isAtEnd: Bool {
        index >= source.endIndex
    }

    func location() -> SourceLocation {
        SourceLocation(file: file, line: line, column: column)
    }

    func peek() -> Character? {
        guard !isAtEnd else { return nil }
        return source[index]
    }

    func peek(offset: Int) -> Character? {
        guard offset >= 0 else { return nil }
        var cursor = index
        for _ in 0..<offset {
            guard cursor < source.endIndex else { return nil }
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex else { return nil }
        return source[cursor]
    }

    mutating func advance() -> Character? {
        guard !isAtEnd else { return nil }
        let character = source[index]
        index = source.index(after: index)

        if character == "\r" {
            if peek() == "\n" {
                index = source.index(after: index)
            }
            line += 1
            column = 1
            return "\n"
        }

        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }

        return character
    }

    mutating func consume(_ expected: Character) -> Bool {
        guard peek() == expected else { return false }
        _ = advance()
        return true
    }

    mutating func consumeIf(where predicate: (Character) -> Bool) -> Character? {
        guard let next = peek(), predicate(next) else { return nil }
        return advance()
    }

    mutating func consumeWhitespace(excludingNewline: Bool = true) {
        while let next = peek() {
            if next == " " || next == "\t" {
                _ = advance()
                continue
            }
            if !excludingNewline && next == "\n" {
                _ = advance()
                continue
            }
            break
        }
    }

    mutating func consumeComment() {
        guard peek() == "#" else { return }
        while let next = peek(), next != "\n" {
            _ = advance()
        }
    }

    mutating func consumeLineBreaks() {
        while peek() == "\n" {
            _ = advance()
        }
    }

    mutating func consumeUTF8BOMIfPresent() {
        guard line == 1, column == 1, peek() == "\u{FEFF}" else { return }
        _ = advance()
    }

    mutating func readWhile(_ predicate: (Character) -> Bool) -> String {
        var output = ""
        while let next = peek(), predicate(next) {
            output.append(advance() ?? next)
        }
        return output
    }
}

private struct Parser {
    private var scanner: Scanner
    private var root: TomlTable = [:]
    private var currentTablePath: [String] = []
    private var declaredTables: Set<String> = []

    init(file: String, source: String) {
        scanner = Scanner(file: file, source: source)
    }

    mutating func parse() throws -> TomlTable {
        scanner.consumeUTF8BOMIfPresent()

        while true {
            try skipTriviaAndBlankLines()
            if scanner.isAtEnd {
                break
            }

            if scanner.peek() == "[" {
                try parseTableHeader()
            } else {
                try parseKeyValuePair(into: currentTablePath)
            }

            scanner.consumeWhitespace()
            scanner.consumeComment()

            if scanner.isAtEnd {
                break
            }

            guard scanner.consume("\n") else {
                throw parseError(
                    kind: .syntax,
                    message: "expected end of line",
                    expected: ["newline"],
                    found: tokenDescription(scanner.peek())
                )
            }
        }

        return root
    }

    private mutating func skipTriviaAndBlankLines() throws {
        while true {
            scanner.consumeWhitespace()

            if scanner.peek() == "#" {
                scanner.consumeComment()
            }

            if scanner.peek() == "\n" {
                scanner.consumeLineBreaks()
                continue
            }

            break
        }
    }

    private mutating func parseTableHeader() throws {
        let headerStart = scanner.location()
        _ = scanner.advance() // [

        if scanner.peek() == "[" {
            throw parseError(
                at: headerStart,
                kind: .unsupportedFeature,
                message: "arrays-of-tables are not supported",
                expected: ["[table]"],
                found: "[["
            )
        }

        scanner.consumeWhitespace()
        var path: [String] = []

        while true {
            let segment = try parseBareKey(expected: "table name")
            path.append(segment)
            scanner.consumeWhitespace()

            if scanner.consume("]") {
                break
            }

            guard scanner.consume(".") else {
                throw parseError(
                    kind: .syntax,
                    message: "invalid table header",
                    expected: [".", "]"],
                    found: tokenDescription(scanner.peek())
                )
            }

            scanner.consumeWhitespace()
        }

        guard !path.isEmpty else {
            throw parseError(
                kind: .syntax,
                message: "empty table header",
                expected: ["table name"],
                found: tokenDescription(scanner.peek())
            )
        }

        let pathKey = path.joined(separator: ".")
        if declaredTables.contains(pathKey) {
            throw parseError(
                kind: .duplicateKey,
                message: "duplicate table declaration",
                expected: [],
                found: pathKey
            )
        }
        declaredTables.insert(pathKey)

        try declareTable(path: path)
        currentTablePath = path
    }

    private mutating func parseKeyValuePair(into tablePath: [String]) throws {
        let key = try parseBareKey(expected: "key")
        scanner.consumeWhitespace()

        guard scanner.consume("=") else {
            throw parseError(
                kind: .syntax,
                message: "missing '=' after key",
                expected: ["="],
                found: tokenDescription(scanner.peek())
            )
        }

        scanner.consumeWhitespace()
        let value = try parseValue()
        try setValue(value, for: key, in: tablePath)
    }

    private mutating func parseValue() throws -> TomlValue {
        guard let next = scanner.peek() else {
            throw parseError(
                kind: .syntax,
                message: "expected value",
                expected: ["value"],
                found: "<eof>"
            )
        }

        if next == "#" {
            throw parseError(
                kind: .syntax,
                message: "expected value",
                expected: ["value"],
                found: "#"
            )
        }

        if next == "\"" {
            return .string(try parseQuotedString())
        }

        if next == "'" {
            throw parseError(
                kind: .unsupportedFeature,
                message: "single-quoted strings are not supported",
                expected: ["double-quoted string"],
                found: "'"
            )
        }

        if next == "{" {
            return .table(try parseInlineTable())
        }

        if next == "[" {
            throw parseError(
                kind: .unsupportedFeature,
                message: "arrays are not supported",
                expected: ["scalar value", "inline table"],
                found: "["
            )
        }

        if next == "-" || next.isNumber {
            return try parseNumberValue()
        }

        if next.isLetter {
            let word = scanner.readWhile { $0.isLetter || $0.isNumber || $0 == "_" }
            switch word {
            case "true":
                return .boolean(true)
            case "false":
                return .boolean(false)
            case "null":
                return .null
            default:
                throw parseError(
                    kind: .invalidValue,
                    message: "unsupported bare value",
                    expected: ["string", "number", "boolean", "null"],
                    found: word
                )
            }
        }

        throw parseError(
            kind: .syntax,
            message: "expected value",
            expected: ["string", "number", "boolean", "inline table", "null"],
            found: tokenDescription(next)
        )
    }

    private mutating func parseQuotedString() throws -> String {
        let start = scanner.location()
        guard scanner.consume("\"") else {
            throw parseError(
                at: start,
                kind: .syntax,
                message: "expected string",
                expected: ["\""],
                found: tokenDescription(scanner.peek())
            )
        }

        if scanner.peek() == "\"", scanner.peek(offset: 1) == "\"" {
            throw parseError(
                at: start,
                kind: .unsupportedFeature,
                message: "multi-line strings are not supported",
                expected: ["single-line string"],
                found: "\"\"\""
            )
        }

        var output = ""

        while let next = scanner.peek() {
            if next == "\"" {
                _ = scanner.advance()
                return output
            }

            if next == "\n" {
                throw parseError(
                    kind: .unterminatedString,
                    message: "unterminated string",
                    expected: ["\""],
                    found: "newline"
                )
            }

            if next == "\\" {
                _ = scanner.advance()
                output.append(try parseEscapeSequence())
                continue
            }

            output.append(scanner.advance() ?? next)
        }

        throw parseError(
            kind: .unterminatedString,
            message: "unterminated string",
            expected: ["\""],
            found: "<eof>"
        )
    }

    private mutating func parseEscapeSequence() throws -> Character {
        guard let escape = scanner.advance() else {
            throw parseError(
                kind: .unterminatedString,
                message: "unterminated escape sequence",
                expected: ["escape code"],
                found: "<eof>"
            )
        }

        switch escape {
        case "n":
            return "\n"
        case "t":
            return "\t"
        case "\"":
            return "\""
        case "\\":
            return "\\"
        case "u":
            let hex = scanner.readWhile { $0.isHexDigit }
            guard hex.count == 4,
                  let scalar = UInt32(hex, radix: 16),
                  let unicode = UnicodeScalar(scalar)
            else {
                throw parseError(
                    kind: .invalidValue,
                    message: "invalid unicode escape",
                    expected: ["\\uXXXX"],
                    found: "\\u\(hex)"
                )
            }
            return Character(unicode)
        default:
            throw parseError(
                kind: .invalidValue,
                message: "invalid escape sequence",
                expected: ["\\n", "\\t", "\\\"", "\\\\", "\\uXXXX"],
                found: "\\\(escape)"
            )
        }
    }

    private mutating func parseNumberValue() throws -> TomlValue {
        let token = scanner.readWhile { character in
            character.isNumber || character == "-" || character == "+" || character == "." || character == "e" || character == "E"
        }

        if token.contains(".") || token.contains("e") || token.contains("E") {
            guard let value = Double(token) else {
                throw parseError(
                    kind: .invalidValue,
                    message: "invalid number literal",
                    expected: ["floating-point number"],
                    found: token
                )
            }
            return .double(value)
        }

        guard let value = Int64(token) else {
            throw parseError(
                kind: .invalidValue,
                message: "invalid number literal",
                expected: ["integer"],
                found: token
            )
        }
        return .integer(value)
    }

    private mutating func parseInlineTable() throws -> TomlTable {
        guard scanner.consume("{") else {
            throw parseError(
                kind: .syntax,
                message: "expected inline table",
                expected: ["{"],
                found: tokenDescription(scanner.peek())
            )
        }

        var table: TomlTable = [:]
        scanner.consumeWhitespace()

        if scanner.consume("}") {
            return table
        }

        while true {
            if scanner.peek() == "\n" {
                throw parseError(
                    kind: .unsupportedFeature,
                    message: "multi-line inline tables are not supported",
                    expected: ["}"],
                    found: "newline"
                )
            }

            let key = try parseBareKey(expected: "inline table key")
            scanner.consumeWhitespace()

            guard scanner.consume("=") else {
                throw parseError(
                    kind: .syntax,
                    message: "missing '=' in inline table",
                    expected: ["="],
                    found: tokenDescription(scanner.peek())
                )
            }

            scanner.consumeWhitespace()
            let value = try parseValue()

            if table[key] != nil {
                throw parseError(
                    kind: .duplicateKey,
                    message: "duplicate key in inline table",
                    expected: [],
                    found: key
                )
            }
            table[key] = value

            scanner.consumeWhitespace()

            if scanner.consume("}") {
                return table
            }

            guard scanner.consume(",") else {
                throw parseError(
                    kind: .syntax,
                    message: "expected ',' or '}' in inline table",
                    expected: [",", "}"],
                    found: tokenDescription(scanner.peek())
                )
            }

            scanner.consumeWhitespace()
            if scanner.peek() == "}" {
                throw parseError(
                    kind: .unsupportedFeature,
                    message: "trailing comma in inline table is not supported",
                    expected: ["inline table entry"],
                    found: "}"
                )
            }
        }
    }

    private mutating func parseBareKey(expected: String) throws -> String {
        let key = scanner.readWhile { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }

        guard !key.isEmpty else {
            throw parseError(
                kind: .syntax,
                message: "expected \(expected)",
                expected: [expected],
                found: tokenDescription(scanner.peek())
            )
        }

        return key
    }

    private mutating func declareTable(path: [String]) throws {
        var rootCopy = root
        try declareTable(path: path, index: 0, in: &rootCopy)
        root = rootCopy
    }

    private mutating func declareTable(path: [String], index: Int, in table: inout TomlTable) throws {
        guard index < path.count else { return }
        let segment = path[index]

        if index == path.count - 1 {
            if let existing = table[segment] {
                guard case let .table(existingTable) = existing else {
                    throw parseError(
                        kind: .syntax,
                        message: "table path conflicts with non-table value",
                        expected: ["table"],
                        found: segment
                    )
                }
                table[segment] = .table(existingTable)
            } else {
                table[segment] = .table([:])
            }
            return
        }

        var childTable: TomlTable
        if let existing = table[segment] {
            guard case let .table(existingTable) = existing else {
                throw parseError(
                    kind: .syntax,
                    message: "table path conflicts with non-table value",
                    expected: ["table"],
                    found: segment
                )
            }
            childTable = existingTable
        } else {
            childTable = [:]
        }

        try declareTable(path: path, index: index + 1, in: &childTable)
        table[segment] = .table(childTable)
    }

    private mutating func setValue(_ value: TomlValue, for key: String, in path: [String]) throws {
        var rootCopy = root
        try setValue(value, for: key, in: path, index: 0, table: &rootCopy)
        root = rootCopy
    }

    private mutating func setValue(
        _ value: TomlValue,
        for key: String,
        in path: [String],
        index: Int,
        table: inout TomlTable
    ) throws {
        if index == path.count {
            if table[key] != nil {
                throw parseError(
                    kind: .duplicateKey,
                    message: "duplicate key",
                    expected: [],
                    found: key
                )
            }
            table[key] = value
            return
        }

        let segment = path[index]
        var childTable: TomlTable

        if let existing = table[segment] {
            guard case let .table(existingTable) = existing else {
                throw parseError(
                    kind: .syntax,
                    message: "table path conflicts with non-table value",
                    expected: ["table"],
                    found: segment
                )
            }
            childTable = existingTable
        } else {
            childTable = [:]
        }

        try setValue(value, for: key, in: path, index: index + 1, table: &childTable)
        table[segment] = .table(childTable)
    }

    private func tokenDescription(_ token: Character?) -> String {
        guard let token else { return "<eof>" }
        return String(token)
    }

    private func parseError(
        at location: SourceLocation? = nil,
        kind: TomlParseErrorKind,
        message: String,
        expected: [String],
        found: String?
    ) -> TomlParseError {
        let location = location ?? scanner.location()
        return TomlParseError(
            file: location.file,
            line: location.line,
            column: location.column,
            kind: kind,
            message: message,
            expectedTokens: expected,
            foundToken: found
        )
    }
}
