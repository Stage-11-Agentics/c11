import Foundation

public enum ThemedValueParseErrorKind: String, Equatable, Sendable {
    case syntax
    case invalidHex
    case unknownModifier
}

public struct ThemedValueParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let kind: ThemedValueParseErrorKind
    public let message: String
    public let position: Int

    public var description: String {
        "\(message) (at offset \(position))"
    }
}

public struct ThemedValueParser {
    public let source: String

    public init(source: String) {
        self.source = source
    }

    public static func parse(_ source: String) throws -> ThemedValueAST {
        try ThemedValueParser(source: source).parse()
    }

    public func parse() throws -> ThemedValueAST {
        var parser = Parser(source: source)
        return try parser.parse()
    }
}

private struct Parser {
    private let source: String
    private var index: String.Index

    init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func parse() throws -> ThemedValueAST {
        consumeWhitespace()
        let value = try parseExpression()
        consumeWhitespace()

        guard isAtEnd else {
            throw error(kind: .syntax, message: "unexpected trailing input")
        }

        return value
    }

    private mutating func parseExpression() throws -> ThemedValueAST {
        guard let next = peek() else {
            throw error(kind: .syntax, message: "expected value expression")
        }

        if next == "$" {
            return try parseVariableExpression()
        }
        if next == "#" {
            return try parseHexLiteral()
        }
        if next == "-" || next.isNumber {
            return .structured(.number(try parseNumberLiteral()))
        }
        if next.isLetter {
            let keyword = parseIdentifier()
            switch keyword {
            case "true":
                return .structured(.boolean(true))
            case "false":
                return .structured(.boolean(false))
            default:
                throw error(kind: .syntax, message: "unsupported bare identifier '\(keyword)'")
            }
        }

        throw error(kind: .syntax, message: "expected expression")
    }

    private mutating func parseVariableExpression() throws -> ThemedValueAST {
        guard consume("$") else {
            throw error(kind: .syntax, message: "expected '$'")
        }

        var path: [String] = [try parseRequiredIdentifier(context: "variable")]

        while consume(".") {
            let segment = try parseRequiredIdentifier(context: "identifier")

            if peek() == "(" {
                var expression: ThemedValueAST = .variableRef(path)
                expression = try parseModifierChain(firstName: segment, base: expression)
                return expression
            }

            guard segment.first?.isLowercase == true else {
                throw error(
                    kind: .syntax,
                    message: "dot-path segment '\(segment)' must begin with lowercase or be a modifier invocation"
                )
            }
            path.append(segment)
        }

        return .variableRef(path)
    }

    private mutating func parseModifierChain(
        firstName: String,
        base: ThemedValueAST
    ) throws -> ThemedValueAST {
        var current = base
        var name = firstName

        while true {
            let op = try parseModifier(name)
            let args = try parseModifierArguments()
            current = .modifier(op: op, args: [current] + args)

            guard consume(".") else {
                break
            }
            name = try parseRequiredIdentifier(context: "modifier")
        }

        return current
    }

    private func parseModifier(_ name: String) throws -> ThemedValueAST.ModifierOp {
        guard let op = ThemedValueAST.ModifierOp(rawValue: name) else {
            throw error(kind: .unknownModifier, message: "unknown modifier '\(name)'")
        }
        return op
    }

    private mutating func parseModifierArguments() throws -> [ThemedValueAST] {
        guard consume("(") else {
            throw error(kind: .syntax, message: "expected '(' after modifier")
        }

        consumeWhitespace()
        if consume(")") {
            return []
        }

        var arguments: [ThemedValueAST] = []

        while true {
            consumeWhitespace()
            let expression = try parseExpression()
            arguments.append(expression)
            consumeWhitespace()

            if consume(")") {
                break
            }

            guard consume(",") else {
                throw error(kind: .syntax, message: "expected ',' or ')' in modifier argument list")
            }
        }

        return arguments
    }

    private mutating func parseHexLiteral() throws -> ThemedValueAST {
        guard consume("#") else {
            throw error(kind: .invalidHex, message: "hex literal must start with '#'")
        }

        let literal = readWhile { $0.isHexDigit }
        guard literal.count == 6 || literal.count == 8,
              let value = UInt32(literal, radix: 16)
        else {
            throw error(kind: .invalidHex, message: "expected 6 or 8 hex digits")
        }

        return literal.count == 8 ? .rgba(value) : .hex(value)
    }

    private mutating func parseNumberLiteral() throws -> Double {
        let number = readWhile { character in
            character.isNumber || character == "." || character == "-" || character == "+" || character == "e" || character == "E"
        }

        guard let value = Double(number) else {
            throw error(kind: .syntax, message: "invalid numeric literal")
        }
        return value
    }

    private mutating func parseRequiredIdentifier(context: String) throws -> String {
        let identifier = parseIdentifier()
        guard !identifier.isEmpty else {
            throw error(kind: .syntax, message: "expected \(context) identifier")
        }
        return identifier
    }

    private mutating func parseIdentifier() -> String {
        readWhile { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
    }

    private mutating func consumeWhitespace() {
        _ = readWhile { $0.isWhitespace }
    }

    private var isAtEnd: Bool {
        index >= source.endIndex
    }

    private func peek() -> Character? {
        guard !isAtEnd else { return nil }
        return source[index]
    }

    private mutating func advance() -> Character? {
        guard !isAtEnd else { return nil }
        let current = source[index]
        index = source.index(after: index)
        return current
    }

    @discardableResult
    private mutating func consume(_ expected: Character) -> Bool {
        guard peek() == expected else { return false }
        _ = advance()
        return true
    }

    private mutating func readWhile(_ predicate: (Character) -> Bool) -> String {
        var value = ""
        while let next = peek(), predicate(next) {
            value.append(advance() ?? next)
        }
        return value
    }

    private func error(kind: ThemedValueParseErrorKind, message: String) -> ThemedValueParseError {
        ThemedValueParseError(kind: kind, message: message, position: source.distance(from: source.startIndex, to: index))
    }
}
