import Foundation
import Testing
@testable import OrgCore

struct CalcNumericTests {
    /// A random real number up to `scale` digits before the point: an integer, a fraction or
    /// a float, tiny to large.
    static func argument(_ generator: inout SystemRandomNumberGenerator, scale: Int = 6) -> String {
        let sign = Bool.random(using: &generator) ? "-" : ""
        let digits = Int.random(in: 1...9, using: &generator)
        let mantissa = String(Int.random(in: 1...999_999_999, using: &generator)).prefix(digits)
        switch Int.random(in: 0..<5, using: &generator) {
        case 0: return sign + String(Int.random(in: 0...(scale > 2 ? 720 : 70), using: &generator))
        case 1: return sign + "\(Int.random(in: 1...99, using: &generator)):\(Int.random(in: 2...99, using: &generator))"
        case 2: return sign + "\(mantissa)e\(Int.random(in: -30...(scale - mantissa.count), using: &generator))"
        case 3: return sign + "\(mantissa)e\(Int.random(in: -mantissa.count - 1...(scale - mantissa.count), using: &generator))"
        default: return sign + ["90.", "180.", "45", "30", "1.5707963267949", "3.14159265358979", "0.785398163397448", "1", "1.", "0.5",
                                "1e-10", "6.28318530717959", "7.", "7.00000000000001"].randomElement(using: &generator)!
        }
    }

    /// A random number from -1 to 1.
    static func unit(_ generator: inout SystemRandomNumberGenerator) -> String {
        let sign = Bool.random(using: &generator) ? "-" : ""
        let mantissa = String(Int.random(in: 1...999_999_999, using: &generator)).prefix(Int.random(in: 1...9, using: &generator))
        switch Int.random(in: 0..<4, using: &generator) {
        case 0: return sign + ["0", "1", "1.", "0.5", "0.", "0.999999999999", "1e-10"].randomElement(using: &generator)!
        case 1:
            let d = Int.random(in: 2...99, using: &generator)
            return sign + "\(Int.random(in: 1..<d, using: &generator)):\(d)"
        case 2: return sign + "\(mantissa)e\(-mantissa.count - Int.random(in: 0...20, using: &generator))"
        default: return sign + "0.\(mantissa)"
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func trigonometryMatchesCalc() throws {
        var generator = SystemRandomNumberGenerator()
        for precision in [3, 6, 8, 12, 14, 15, 16, 17, 18] {
            for radians in [false, true] {
                var cases: [(String, String)] = ["sin(nan)", "cos(nan)", "arctan(nan)", "tan(180)", "tan(-360)", "tan(0)", "arcsin(0)",
                                                 "arccos(1)", "arccos(0)", "arcsin(-1)", "arctan(1)", "sqrt(2)", "sqrt(1e-9)"].map { ($0, "(float 0)") }
                for _ in 0..<500 {
                    let f = ["sin", "cos", "tan", "arcsin", "arccos", "arctan", "arctan2", "sinh", "cosh", "tanh", "sqrt"].randomElement(using: &generator)!
                    let x = switch f {
                    case "arcsin", "arccos": Self.unit(&generator)
                    case "arctan2": Self.argument(&generator) + "," + Self.argument(&generator)
                    case "sinh", "cosh", "tanh": Self.argument(&generator, scale: 1)
                    case "sqrt": Self.argument(&generator).replacingOccurrences(of: "-", with: "")
                    default: Self.argument(&generator)
                    }
                    cases.append(("\(f)(\(x))", "(float 0)"))
                }
                var modes = Calc.Modes()
                (modes.precision, modes.degrees, modes.format) = (precision, !radians, .float(0))
                var refused: [String] = []
                for (c, expected) in zip(cases, try CalcOracle.run(cases, precision: precision, radians: radians)) {
                    guard let ours = try? Calc.evaluate(c.0, modes: modes) else {
                        // Calc keeps a tangent of a quotient by zero unevaluated, and Calc's exp
                        // past 16 digits, worked out at two (four for tanh) digits more, isn't reproduced. Past
                        // 16 digits, two more don't always fit in a mantissa.
                        let name = String(c.0.prefix { $0 != "(" })
                        if precision <= 16, !expected.hasPrefix(name + "("), !(precision >= 13 && name == "tanh"), !(precision >= 15 && ["sinh", "cosh"].contains(name)) {
                            refused.append(c.0)
                        }
                        continue
                    }
                    #expect(ours == expected, "\(c.0) p\(precision) \(radians ? "rad" : "deg")")
                }
                #expect(refused == [], "p\(precision) \(radians ? "rad" : "deg") \(refused)")
            }
        }
    }
}
