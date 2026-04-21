import XCTest
@testable import cmux

final class ThemeRegistryTests: XCTestCase {
    func testEveryThemeRoleDeclaresDefaultValue() {
        for role in ThemeRole.allCases {
            let definition = role.definition
            switch definition.expectedType {
            case .color:
                XCTAssertNotNil(definition.defaultColorExpression, "missing color default for \(role.rawValue)")
            case .number:
                XCTAssertNotNil(definition.defaultNumber, "missing number default for \(role.rawValue)")
            case .boolean:
                XCTAssertNotNil(definition.defaultBoolean, "missing boolean default for \(role.rawValue)")
            }
        }
    }
}
