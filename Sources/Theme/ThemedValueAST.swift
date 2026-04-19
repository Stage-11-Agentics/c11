import Foundation

public indirect enum ThemedValueAST: Equatable, Sendable {
    case hex(UInt32)
    case variableRef([String])
    case modifier(op: ModifierOp, args: [ThemedValueAST])
    case structured(StructuredValue)

    public enum ModifierOp: String, Equatable, Sendable, CaseIterable {
        case opacity
        case mix
        case darken
        case lighten
        case saturate
        case desaturate
    }

    public enum StructuredValue: Equatable, Sendable {
        case disabled
        case opacityValue(Double)
        case hexLiteral(UInt32)
        case number(Double)
        case boolean(Bool)
        case text(String)
    }
}
