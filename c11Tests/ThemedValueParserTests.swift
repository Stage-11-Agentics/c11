import XCTest
@testable import c11

final class ThemedValueParserTests: XCTestCase {
    func testParsesVariableDotPath() throws {
        let ast = try ThemedValueParser.parse("$palette.void")
        XCTAssertEqual(ast, .variableRef(["palette", "void"]))
    }

    func testParsesWorkspaceOpacityModifier() throws {
        let ast = try ThemedValueParser.parse("$workspaceColor.opacity(0.5)")

        guard case let .modifier(op, args) = ast else {
            return XCTFail("expected modifier AST")
        }

        XCTAssertEqual(op, .opacity)
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0], .variableRef(["workspaceColor"]))
        XCTAssertEqual(args[1], .structured(.number(0.5)))
    }

    func testParsesDotPathThenModifierChain() throws {
        let ast = try ThemedValueParser.parse("$palette.void.opacity(0.5)")

        guard case let .modifier(op, args) = ast else {
            return XCTFail("expected modifier AST")
        }

        XCTAssertEqual(op, .opacity)
        XCTAssertEqual(args[0], .variableRef(["palette", "void"]))
        XCTAssertEqual(args[1], .structured(.number(0.5)))
    }

    func testParsesMixWithNestedVariableReference() throws {
        let ast = try ThemedValueParser.parse("$a.mix($b, 0.3)")

        guard case let .modifier(op, args) = ast else {
            return XCTFail("expected modifier AST")
        }

        XCTAssertEqual(op, .mix)
        XCTAssertEqual(args.count, 3)
        XCTAssertEqual(args[0], .variableRef(["a"]))
        XCTAssertEqual(args[1], .variableRef(["b"]))
        XCTAssertEqual(args[2], .structured(.number(0.3)))
    }
}
