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
                                                 "arccos(1)", "arccos(0)", "arcsin(-1)", "arctan(1)", "sqrt(2)", "sqrt(1e-9)", "sin(-74250)", "cos(-74250)",
                                                 "sin(-360000000000090)", "cos(-90*4000000000001)", "tan(-360000000000180)"].map { ($0, "(float 0)") }
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func zeroInEveryFormatMatchesCalc() throws {
        var cases: [(String, String)] = []
        for kind in ["float", "fix", "sci", "eng"] {
            for figs in [0, 1, 2, 3, 8, -2] {
                for e in ["0.", "-0.", "0.0", "1-1.0", "0./0", "0.e5", "0.001", "0.5", "-0.4", "4e-5", "123.456"] {
                    cases.append((e, "(\(kind) \(figs))"))
                }
            }
        }
        let skipped = try CalcTests.compare(cases)
        #expect(skipped == [], "\(skipped)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func fractionModeMatchesCalc() throws {
        var generator = SystemRandomNumberGenerator()
        let numbers = ["0", "1", "2", "3", "-2", "7", "10", "12", "1:2", "1:3", "-5:4", "7:2", "-3:7", "0.5", "2.5", "-1.5", "0.25", "3.", "1.2e1",
                       "100", "0.123456789", "0."]
        func number() -> String { numbers.randomElement(using: &generator)! }
        func vector() -> String { "[" + (0..<Int.random(in: 1...5, using: &generator)).map { _ in number() }.joined(separator: ",") + "]" }
        let unary = ["fact", "dfact", "abs", "floor", "ceil", "trunc", "round", "sqrt", "exp", "ln", "log10", "sin", "cos", "tan", "arcsin",
                     "arccos", "arctan", "lnot", "percent", "float", "pfloat", "sign", "rounde", "roundu", "frac", "exp10", "sinh", "cosh",
                     "tanh", "arcsinh", "arccosh", "arctanh", "deg", "rad"]
        let binary = ["mod", "idiv", "max", "min", "round", "rounde", "roundu", "fdiv", "gcd", "lcm", "choose", "perm", "pow", "nroot",
                      "hypot", "log", "arctan2", "eq", "lt", "land", "lor", "agmean"]
        let statistics = ["vsum", "vprod", "vcount", "vmean", "vmax", "vmin", "vmedian", "vvar", "vpvar", "vsdev", "vpsdev", "vflat", "vgmean", "vhmean"]
        var cases = ["vmedian([1,2])", "round(2.5,1)", "round(1:3,2)", "rounde(2.45,1)", "vmean([1,2])", "vmedian([1:3,1])", "7/2", "1/3+1/6",
                     "2^-1", "0.5^-1", "(1:2)^0.5", "4^(1:2)", "8^(-1:3)", "7%2", "7\\2", "<2026-10-05 Mon>+1/2", "vsdev([1,2])",
                     "round(3.,-2)", "round(-2.25,1)", "round(2.5,1.)", "mod(0,0.5)", "0%0.5", "vgmean([0.5])", "vgmean([1:4])"].map { ($0, "(float 12)") }
        for _ in 0..<1500 {
            switch Int.random(in: 0..<4, using: &generator) {
            case 0: cases.append(("\(unary.randomElement(using: &generator)!)(\(number()))", "(float 12)"))
            case 1: cases.append(("\(binary.randomElement(using: &generator)!)(\(number()),\(number()))", "(float 12)"))
            case 2: cases.append(("\(statistics.randomElement(using: &generator)!)(\(vector()))", "(float 12)"))
            default:
                let op = ["+", "-", "*", "/", "^", "%", "\\"].randomElement(using: &generator)!
                cases.append(("(\(number()))\(op)(\(number()))", "(float 12)"))
            }
        }
        for fractions in [true, false] { _ = try CalcTests.compare(cases, fractions: fractions) }
    }

    /// `math-mod` divides as a float, without F, unless both operands are natural numbers.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func modOfNegativeIntegersMatchesCalc() throws {
        let cases = ["(-74251)%4", "mod(74251,-4)", "mod(-1234567890123457,4)", "(-1234567890123457)%7", "mod(-7,2)", "mod(7,-2)",
                     "(-7)%(-2)", "mod(1234567890123457,4)", "(-1234567890123457)\\4", "mod(-7:2,2)", "mod(-1:3,-1:7)"].map { ($0, "(float 0)") }
        for precision in [3, 12] {
            for fractions in [true, false] {
                let skipped = try CalcTests.compare(cases, precision: precision, fractions: fractions)
                #expect(skipped == [], "p\(precision) \(skipped)")
            }
        }
        let wide = ["mod(-1234567890123456789,7)", "(-1234567890123456789)%7", "mod(1234567890123456789,-7)", "mod(-29999999999999999,-10)",
                    "(-29999999999999999)%(-10)", "mod(-9999999999999999,-10)"].map { ($0, "(float 0)") }
        for precision in [16, 17, 18] {
            for fractions in [true, false] {
                let skipped = try CalcTests.compare(wide, precision: precision, fractions: fractions)
                #expect(skipped == [], "p\(precision) \(skipped)")
            }
        }
    }

    /// Calc's `math-overflow` and `math-underflow` past an exponent of 4,000,000 leave the formula alone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func floatOverflowIsRefusedAsCalcDoes() throws {
        let refused = ["2.5^123456789012", "pow(-1.5,123456789012)", "pow(1e20,123456789012)", "0.4^123456789012", "2.5^(-123456789012)"]
        let cases = (refused + ["2.5^1000000", "0.4^1000000"]).map { ($0, "(float 0)") }
        for fractions in [true, false] {
            let skipped = try CalcTests.compare(cases, fractions: fractions)
            #expect(skipped == refused)
        }
    }

    /// Vector results, with and without `N`, zero with no decimal places, and fractions.
    static let tables = [
        "| 1 | 2 | | |\n|---+---+---+---|\n| 2.5 | 0.25 | | |\n#+TBLFM: $3=vmedian($1..$2);F::$4=round($1,1);F\n",
        "| 1 | 2 | |\n|---+---+---|\n| 3 | x | |\n| 1.5 | 0. | |\n#+TBLFM: $3=$1..$2;N\n",
        "| 1 | 2 | |\n|---+---+---|\n| 1.5 | 0. | |\n| 1:3 | -2 | |\n#+TBLFM: $3=$1..$2\n",
        "| 1.5 | 0 | |\n|---+---+---|\n| 2 | 4 | |\n#+TBLFM: $3=$1..$2;Nf0\n",
        "| 1 | 2 | |\n|---+---+---|\n| 3 | 4 | |\n#+TBLFM: @1$3=@1$1..@2$2;N::@2$3=vflat(@1$1..@2$2);N\n",
        "| 1 | 2 | |\n#+TBLFM: $3=[$1, [$2]];N\n",
        "| 0 | | | |\n|---+---+---+---|\n| 0.5 | | | |\n#+TBLFM: $2=$1*1.0;f0::$3=($1-$1)*1.;s2::$4=($1-$1)*1./0;f0\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func vectorsAndZeroInTablesMatchEmacsNatively() throws {
        try TableFormulaTests().compare(Self.tables, fallbacksAllowed: false, headerFallbacksAllowed: false)
    }
}
