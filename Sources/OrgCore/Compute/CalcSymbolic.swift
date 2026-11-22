import Foundation

/// Calc's arithmetic on formulas it can't reduce to a number: variables, `inf`, `uinf`, and
/// quotients by zero. This ports `math-add`, `math-mul`, `math-div`, `math-pow` and `math-neg`
/// with their `-symb-fancy` helpers from calc.el and calc-arith.el, as `calc-eval` runs them
/// with `calc-simplify-mode` nil; `math-sqrt`, `math-abs`, `math-mod`, `calcFunc-exp`, `calcFunc-ln`,
/// `calcFunc-min`, `calcFunc-max` and the comparisons and logical functions of calc-prog.el on
/// formulas; and Calc's flat formula printer from calccomp.el. Anything
/// those functions would decide from declarations, units, matrices or intervals throws
/// `Calc.Unsupported`.
extension Calc {
    /// A formula, as Calc's Lisp form: a number, a variable, or an operator or function with
    /// its arguments (`+ - * / ^ neg`, or a function name).
    public indirect enum Term: Equatable, Sendable {
        case number(Value)
        case variable(String)
        case op(String, [Term])
    }

    /// `math-reject-arg`: the operation stays unevaluated.
    struct Rejected: Error {}

    /// `calc-symbolic-mode`.
    @TaskLocal static var symbolicMode = false

    /// `calc-prefer-frac`, for the division the arithmetic does.
    @TaskLocal static var fractions = false

    /// How deeply `mul` calls itself in one evaluation. Some products rewrite themselves
    /// without end, where Calc stops at `max-lisp-eval-depth`; past `limit` they are refused.
    final class Nesting: @unchecked Sendable {
        static let limit = 64
        var depth = 0
    }
    @TaskLocal static var nesting: Nesting?

    /// Variables Calc gives a value or a declaration, which would change the arithmetic.
    static let reserved: Set<String> = ["CommuteRules", "Decls", "DistribRules", "EvalRules", "FactorRules", "FitRules",
                                        "Holidays", "IntegAfterRules", "InvertRules", "JumpRules", "MergeRules", "Modes",
                                        "NegateRules"]

    /// The special constants and infinities, whose sign or type Calc knows.
    static let constants: Set<String> = ["pi", "e", "phi", "gamma", "i", "inf", "uinf", "nan"]

    static func term(_ v: Value) throws -> Term {
        switch v {
        case .symbolic(let t): return t
        case .nan: return .variable("nan")
        case .int, .float, .frac: return .number(v)
        case .vector, .date: throw Unsupported("symbolic arithmetic")
        }
    }

    static func value(_ t: Term) -> Value {
        switch t {
        case .number(let v): return v
        case .variable("nan"): return .nan
        default: return .symbolic(t)
        }
    }

    enum Symbolic {
        static let inf = Term.variable("inf")
        static let uinf = Term.variable("uinf")
        static let nan = Term.variable("nan")

        // MARK: Predicates

        static func number(_ t: Term) -> Value? {
            if case .number(let v) = t { return v }
            return nil
        }

        static func head(_ t: Term) -> String? {
            if case .op(let f, _) = t { return f }
            return nil
        }

        /// `(nth n a)`, from 1.
        static func arg(_ t: Term, _ n: Int) -> Term {
            guard case .op(_, let args) = t, n - 1 < args.count else { return .number(.int(0)) }
            return args[n - 1]
        }

        static func objectp(_ t: Term) -> Bool { number(t) != nil }
        static func zerop(_ t: Term) -> Bool { number(t).map(isZero) ?? false }
        static func floatp(_ t: Term) -> Bool {
            if case .number(.float) = t { return true }
            return false
        }
        static func ratp(_ t: Term) -> Bool { number(t).map { rational($0) != nil } ?? false }
        static func integerp(_ t: Term) -> Bool {
            if case .number(.int) = t { return true }
            return false
        }

        /// `math-negp`.
        static func negp(_ t: Term) -> Bool {
            if let v = number(t) { return (try? sign(v)) == -1 }
            return t == .op("neg", [inf])
        }

        /// `math-posp`.
        static func posp(_ t: Term) -> Bool {
            if let v = number(t) { return (try? sign(v)) == 1 }
            return t == inf
        }

        /// `Math-equal-int`.
        static func equalInt(_ t: Term, _ n: Int) -> Bool {
            t == .number(.int(n)) || t == .number(.float(n, 0))
        }

        /// `math-looks-negp`; `loose` false is the `Math-looks-negp` macro, which doesn't
        /// look inside a difference.
        static func looksNeg(_ t: Term, loose: Bool = true) -> Bool {
            if negp(t) { return true }
            switch head(t) {
            case "neg": return true
            case "*", "/": return looksNeg(arg(t, 1)) || looksNeg(arg(t, 2))
            case "-": return loose && looksNeg(arg(t, 1))
            default: return false
            }
        }

        /// `math-infinitep`: the infinity a product, quotient or negation is made of.
        static func infinitep(_ t: Term) -> Term? {
            var a = t
            while let f = head(a), ["*", "/", "neg"].contains(f) {
                a = f != "*" || infinitep(arg(a, 1)) != nil ? arg(a, 1) : arg(a, 2)
            }
            return [inf, uinf, nan].contains(a) ? a : nil
        }

        static func containsConstant(_ t: Term) -> Bool {
            switch t {
            case .number: false
            case .variable(let name): constants.contains(name)
            case .op(_, let args): args.contains(where: containsConstant)
            }
        }

        /// `math-possible-signs`: the bits 1 negative, 2 zero, 4 positive and 8 not real,
        /// relative to `origin`. Nothing is declared, so a variable may be anything.
        static func signs(_ a: Term, _ origin: Term? = nil) throws -> Int {
            func negSigns(_ s: Int) -> Int {
                s >= 8 ? 8 + negSigns(s - 8) : (s & 1 != 0 ? 4 : 0) | (s & 2) | (s & 4 != 0 ? 1 : 0)
            }
            if objectp(a) {
                let x = try origin.map { try sub(a, $0) } ?? a
                return posp(x) ? 4 : negp(x) ? 1 : 2
            }
            let (a1, a2) = (arg(a, 1), arg(a, 2))
            let f = head(a)
            if f == "+" || f == "-" {
                if objectp(a1) {
                    if f == "-" { return negSigns(try signs(a2, try origin.map { try add($0, a1) } ?? a1)) }
                    return try signs(a2, try origin.map { try sub($0, a1) } ?? (try neg(a1)))
                }
                if objectp(a2) {
                    let org = f == "-" ? a2 : try neg(a2)
                    return try signs(a1, try origin.map { try add($0, org) } ?? org)
                }
                let s1 = try signs(a1, origin)
                var s2 = try signs(a2)
                if f == "-" { s2 = negSigns(s2) }
                if s1 == s2 { return s1 }
                if s1 == 2 { return s2 }
                if s2 == 2 { return s1 }
                if s1 >= 8 || s2 >= 8 { return 15 }
                if (s1, s2) == (4, 6) || (s1, s2) == (6, 4) { return 4 }
                if (s1, s2) == (1, 3) || (s1, s2) == (3, 1) { return 1 }
                return 7
            }
            if f == "neg" { return negSigns(try signs(a1, try origin.map(neg))) }
            var origin = origin.flatMap { zerop($0) ? nil : $0 }
            let zero = Term.number(.int(0))
            if f == "*" || (f == "/" && origin != nil), objectp(a1) {
                let s = f == "*"
                    ? (zerop(a1) ? try signs(zero, origin) : try signs(a2, try div(origin ?? zero, a1)))
                    : negSigns(try signs(a2, try div(a1, origin!)))
                return negp(a1) ? negSigns(s) : s
            }
            if f == "*" || f == "/", objectp(a2) {
                let s = try signs(a1, f == "*" ? try mul(origin ?? zero, a2) : try div(origin ?? zero, a2))
                return negp(a2) ? negSigns(s) : s
            }
            let sign: Int
            switch a {
            case .op("*", _), .op("/", _):
                let (s1, s2) = (try signs(a1), try signs(a2))
                if s1 >= 8 || s2 >= 8 || (f == "/" && [2, 3, 6, 7].contains(s2)) {
                    sign = 15
                } else {
                    sign = (s1 & 4 != 0 ? s2 : 0) | (s1 & 2) | (s1 & 1 != 0 ? negSigns(s2) : 0)
                }
            case .op("^", _):
                let (s1, s2) = (try signs(a1), try signs(a2))
                if s1 >= 8 || s2 >= 8 {
                    sign = 15
                } else if s1 == 4 {
                    sign = 4
                } else if s1 == 2 {
                    sign = s2 == 4 ? 2 : 15
                } else if s2 == 2 {
                    sign = [1, 5].contains(s1) ? 2 : 15
                } else if case .number(.int(let n)) = a2 {
                    sign = n % 2 == 0 ? ([3, 6, 7].contains(s1) ? 6 : 4) : s1
                } else if s1 == 6 {
                    sign = s2 == 4 ? 6 : 15
                } else {
                    sign = 7
                }
            case .variable(let name):
                switch name {
                case "pi", "e":
                    guard origin == nil else { throw Unsupported("symbolic arithmetic") }
                    return 4
                case "inf": return 4
                case "uinf": return 13
                case "i": return 8
                default: return 15
                }
            case .op("%", let args):
                let s2 = try signs(args[1])
                sign = s2 >= 8 ? 7 : s2 == 2 ? 2 : [4, 6].contains(s2) ? 6 : [1, 3].contains(s2) ? 3 : 7
            case .op("abs", let args):
                let s1 = try signs(args[0])
                sign = s1 == 2 ? 2 : [1, 4, 5].contains(s1) ? 4 : 6
            case .op("exp", let args):
                let s1 = try signs(args[0])
                if s1 >= 8 {
                    sign = 15
                } else if origin == nil || negp(origin!) {
                    sign = 4
                } else {
                    origin = try sub(origin!, .number(.int(1)))
                    if zerop(origin!) { origin = nil }
                    sign = s1
                }
            case .op("ln", let args):
                sign = try knownNonneg(args[0]) ? try signs(args[0], .number(.int(1))) : 15
            case .op("sqrt", let args):
                let s1 = try signs(args[0])
                sign = [2, 4, 6].contains(s1) ? s1 : 15
            case .op(let f, _) where ["eq", "neq", "lt", "gt", "leq", "geq", "lnot", "max", "min"].contains(f):
                sign = 7
            // Nothing is declared about the other functions.
            case .op(let f, _) where functions.contains(f) || f == "if": return 15
            default: throw Unsupported("function \(f ?? "")")
            }
            guard let origin else { return sign }
            if posp(origin) { return (sign & 8) + ([1, 2, 3, 8, 9, 10, 11].contains(sign) ? 1 : 7) }
            return (sign & 8) + ([2, 4, 6, 8, 10, 12, 14].contains(sign) ? 4 : 7)
        }

        static func knownNonneg(_ t: Term) throws -> Bool { [2, 4, 6].contains(try signs(t)) }

        static func knownReal(_ t: Term) throws -> Bool { try signs(t) < 8 }

        /// `math-known-evenp`.
        static func knownEven(_ t: Term) throws -> Bool {
            switch t {
            case .number(.int(let n)): return n % 2 == 0
            case .number(.float(let m, let e)) where e >= 0: return e > 0 || m % 2 == 0
            case .op("*", let args):
                if try knownEven(args[0]) { return try knownNumInteger(args[1]) }
                return try knownNumInteger(args[0]) && knownEven(args[1])
            case .op("+", let args), .op("-", let args):
                return try (knownEven(args[0]) && knownEven(args[1])) || (knownOdd(args[0]) && knownOdd(args[1]))
            case .op("neg", let args): return try knownEven(args[0])
            default: return false
            }
        }

        /// `math-known-oddp`.
        static func knownOdd(_ t: Term) throws -> Bool {
            switch t {
            case .number(.int(let n)): return n % 2 != 0
            case .number(.float(let m, let e)) where e >= 0: return e == 0 && m % 2 != 0
            case .op("+", let args), .op("-", let args):
                return try (knownEven(args[0]) && knownOdd(args[1])) || (knownOdd(args[0]) && knownEven(args[1]))
            case .op("neg", let args): return try knownOdd(args[0])
            default: return false
            }
        }

        /// `math-known-num-integerp`.
        static func knownNumInteger(_ t: Term) throws -> Bool {
            if let v = number(t) { return isWhole(v) }
            guard !containsConstant(t) else { throw Unsupported("symbolic arithmetic") }
            return try possibleTypes(t, num: true) <= 3
        }

        /// `math-possible-types`: the bits 1 integer, 2 integer-valued float, 4 fraction and
        /// 8 float, with `num` merging 1 and 2 and merging 4 and 8. Nothing is declared, so a
        /// variable may be anything (63). Results above 15 are all 63 here: only whether a
        /// result is at most 3 is used, and no larger operand can make it so.
        static func possibleTypes(_ a: Term, num: Bool = false) throws -> Int {
            func merge(_ t1: Int, _ t2: Int, _ mask: Int) -> Int {
                if num { return mask * 3 }
                return (t1 & 5 > 0 && t2 & 5 > 0 ? mask : 0) | ((t1 | t2) & 10 > 0 ? mask * 2 : 0)
            }
            switch a {
            case .number(.int): return num ? 3 : 1
            case .number(.float(_, let e)) where e >= 0: return num ? 3 : 2
            case .number(.frac): return num ? 12 : 4
            case .number(.float): return num ? 12 : 8
            case .number: throw Unsupported("symbolic arithmetic")
            case .variable: return 63
            case .op("neg", let args): return try possibleTypes(args[0])
            case .op("sqrt", let args):
                let s1 = try signs(args[0])
                let t = (s1 & 2 > 0 ? 3 : 0) | (s1 & 1 > 0 ? 16 : 0) | (s1 & 4 > 0 ? 15 : 0) | (s1 & 8 > 0 ? 32 : 0)
                return t < 16 ? t : 63
            case .op("abs", let args):
                let t1 = try possibleTypes(args[0])
                return t1 >= 16 ? 15 : t1
            case .op(let f, let args) where args.count == 2 && ["+", "-", "*", "/", "^", "%"].contains(f):
                // `%` keeps only the real bits, which the merged values above 15 don't give.
                if f == "%", args.contains(where: { containsHead($0, "sqrt") }) { throw Unsupported("symbolic arithmetic") }
                var (t1, t2) = (try possibleTypes(args[0], num: num), try possibleTypes(args[1], num: num))
                if f == "%" { (t1, t2) = (t1 & 15, t2 & 15) }
                let t12 = t1 | t2
                if f == "^" {
                    guard t2 <= 3, try knownNonneg(args[1]), t1 < 16 else {
                        return try knownNonneg(args[0]) && signs(args[1]) == 4 ? 15 : 63
                    }
                    let mask = (t1 & 3 > 0 ? 1 : 0) | (t1 & 4) | (t1 & 12 > 0 ? 5 : 0)
                    return merge(t1, t2, mask)
                }
                guard t12 < 16 else { return 63 }
                if f == "/" {
                    if t12 & 10 > 0 { return 10 }
                    return t1 == 4 || t2 == 4 || fractions ? 5 : 15
                }
                let mask = t12 <= 3 ? 1
                    : ((t1 <= 3 && t2 & 3 == 0) || (t2 <= 3 && t1 & 3 == 0)) && (f == "+" || f == "-") ? 4 : 5
                return merge(t1, t2, mask)
            case .op(let f, _) where functions.contains(f) || f == "if": return 63
            default: throw Unsupported("function \(head(a) ?? "")")
            }
        }

        static func containsHead(_ t: Term, _ f: String) -> Bool {
            guard case .op(let g, let args) = t else { return false }
            return g == f || args.contains { containsHead($0, f) }
        }

        // MARK: Arithmetic

        /// `math-normalize`: the operations applied again from the leaves, floats rounded
        /// to the precision.
        static func normalize(_ t: Term) throws -> Term {
            switch t {
            case .number(.float(let m, let e)): return .number(try makeFloat(Int128(m), e))
            case .number, .variable: return t
            // `math-normalize-logical-op`: the branches stay as written unless the condition
            // is a number.
            case .op("if", let args) where args.count == 3:
                let c = try normalize(args[0])
                guard let v = number(c) else { return .op("if", [c, args[1], args[2]]) }
                return try normalize(isZero(v) ? args[2] : args[1])
            case .op(let f, let args):
                let args = try args.map(normalize)
                do { return try apply(f, args) } catch is Rejected { return .op(f, args) }
            }
        }

        static func apply(_ f: String, _ args: [Term]) throws -> Term {
            switch (f, args.count) {
            case ("+", 2): return try add(args[0], args[1])
            case ("-", 2): return try sub(args[0], args[1])
            case ("*", 2): return try mul(args[0], args[1])
            case ("/", 2): return try div(args[0], args[1])
            case ("^", 2): return try pow(args[0], args[1])
            case ("neg", 1): return try neg(args[0])
            default:
                guard functions.contains(f) else { throw Unsupported("function \(f)") }
                return try function(f, args)
            }
        }

        static func numeric(_ a: Term, _ b: Term, _ op: (Value, Value) throws -> Value) throws -> Term? {
            guard let x = number(a), let y = number(b) else { return nil }
            return try term(try op(x, y))
        }

        /// `math-float` of a rational number.
        static func float(_ t: Term) throws -> Term {
            guard let v = number(t) else { return t }
            return .number(try Calc.float(v))
        }

        /// `math-neg`.
        static func neg(_ a: Term) throws -> Term {
            if let v = number(a) { return .number(try negate(v)) }
            func okayNeg(_ t: Term) -> Bool { looksNeg(t) || head(t) == "-" }
            let (a1, a2) = (arg(a, 1), arg(a, 2))
            switch head(a) {
            case "+": return try sub(try neg(a1), a2)
            case "-": return try sub(a2, a1)
            case "*", "/":
                let f = head(a)!
                if okayNeg(a1) { return .op(f, [try neg(a1), a2]) }
                if okayNeg(a2) { return .op(f, [a1, try neg(a2)]) }
                if objectp(a1) || (head(a1) == "*" && objectp(arg(a1, 1))) { return .op(f, [try neg(a1), a2]) }
                if f == "/", objectp(a2) || (head(a2) == "*" && objectp(arg(a2, 1))) { return .op(f, [a1, try neg(a2)]) }
            case "neg": return a1
            default: if a == uinf || a == nan { return a }
            }
            return .op("neg", [a])
        }

        /// `math-add`.
        static func add(_ a: Term, _ b: Term) throws -> Term {
            if let sum = try numeric(a, b, { try Calc.add($0, $1) }) { return sum }
            if zerop(a) { return b }
            if zerop(b) { return a }
            return try addFancy(a, b)
        }

        /// `math-sub`.
        static func sub(_ a: Term, _ b: Term) throws -> Term { try add(a, try neg(b)) }

        /// `math-add-symb-fancy`.
        static func addFancy(_ a: Term, _ b: Term) throws -> Term {
            switch head(b) {
            case "+": return try add(try add(a, arg(b, 1)), arg(b, 2))
            case "-": return try sub(try add(a, arg(b, 1)), arg(b, 2))
            case "neg" where head(arg(b, 1)) == "+":
                return try sub(try sub(a, arg(arg(b, 1), 1)), arg(arg(b, 1), 2))
            default: break
            }
            if let result = try combineSums(a, b) { return result }
            if looksNeg(b, loose: false) { return .op("-", [a, try neg(b)]) }
            if looksNeg(a, loose: false) { return .op("-", [b, try neg(a)]) }
            return .op("+", [a, b])
        }

        /// The `cond` in `math-add-symb-fancy` that handles infinities and like terms.
        static func combineSums(_ a: Term, _ b: Term) throws -> Term? {
            if let infA = infinitep(a) {
                guard let infB = infinitep(b) else { return a }
                if [uinf, nan].contains(infA) || [uinf, nan].contains(infB) { return nan }
                let dirA = try infiniteDirection(a, infA)
                let dirB = try infiniteDirection(b, infB)
                guard let x = number(dirA), let y = number(dirB) else { return nil }
                return try compare(x, y) == 0 ? a : nan
            }
            if infinitep(b) != nil { return b }
            if head(a) == "+" {
                return try combineSum(arg(a, 2), b, negA: false, negB: false, scalarOkay: true).map { try add(arg(a, 1), $0) }
            }
            if head(a) == "-" {
                return try combineSum(arg(a, 2), b, negA: true, negB: false, scalarOkay: true).map { try add(arg(a, 1), $0) }
            }
            if objectp(a), objectp(b) { return nil }
            return try combineSum(a, b, negA: false, negB: false, scalarOkay: false)
        }

        /// `math-infinite-dir`: the formula with its infinity replaced by 1.
        static func infiniteDirection(_ a: Term, _ infinity: Term) throws -> Term {
            func substitute(_ t: Term) -> Term {
                if t == infinity { return .number(.int(1)) }
                if case .op(let f, let args) = t { return .op(f, args.map(substitute)) }
                return t
            }
            return try normalize(substitute(a))
        }

        /// `math-combine-sum`: two terms that are multiples of the same thing, added.
        static func combineSum(_ a: Term, _ b: Term, negA: Bool, negB: Bool, scalarOkay: Bool) throws -> Term? {
            if scalarOkay, objectp(a), objectp(b) {
                return try add(negA ? try neg(a) : a, negB ? try neg(b) : b)
            }
            /// The coefficient and the rest; a nil coefficient is Calc's `(frac 1 0)`.
            func split(_ t: Term) throws -> (Term?, Term) {
                switch head(t) {
                case "*" where objectp(arg(t, 1)): return (arg(t, 1), arg(t, 2))
                case "/" where objectp(arg(t, 2)):
                    let d = arg(t, 2)
                    if case .number(.int(let n)) = d { return (n == 0 ? nil : .number(try fraction(1, n)), arg(t, 1)) }
                    return (try div(.number(.int(1)), d), arg(t, 1))
                case "neg": return (.number(.int(-1)), arg(t, 1))
                default: return (.number(.int(1)), t)
                }
            }
            let (multA, restA) = try split(a)
            let (multB, restB) = try split(b)
            guard restA == restB else { return nil }
            // `math-make-frac` of two such coefficients divides by zero.
            if multA == nil, multB == nil { throw Rejected() }
            guard var ma = multA, var mb = multB else { throw Unsupported("division by zero") }
            if negA { ma = try neg(ma) }
            if negB { mb = try neg(mb) }
            return try mul(try add(ma, mb), restA)
        }

        /// `math-mul`.
        static func mul(_ a: Term, _ b: Term) throws -> Term {
            let nesting = Calc.nesting
            nesting?.depth += 1
            defer { nesting?.depth -= 1 }
            if let nesting, nesting.depth > Nesting.limit { throw Unsupported("symbolic arithmetic") }
            if let product = try numeric(a, b, { try multiply($0, $1) }) { return product }
            if zerop(a) { return try mulZero(a, b) }
            if zerop(b) { return try mulZero(b, a) }
            return try mulFancy(a, b)
        }

        /// `math-mul-zero`, `a` zero and `b` a formula.
        static func mulZero(_ a: Term, _ b: Term) throws -> Term {
            if infinitep(b) != nil { return nan }
            return floatp(a) || floatp(b) ? .number(.float(0, 0)) : .number(.int(0))
        }

        /// `math-mul-symb-fancy`.
        static func mulFancy(_ a: Term, _ b: Term) throws -> Term {
            if equalInt(a, 1) { return b }
            if equalInt(a, -1) { return try neg(b) }
            if objectp(b), !objectp(a) { return try mul(b, a) }
            if head(a) == "neg" { return try neg(try mul(arg(a, 1), b)) }
            if head(b) == "neg" { return try neg(try mul(a, arg(b, 1))) }
            if head(a) == "*" { return try mul(arg(a, 1), try mul(arg(a, 2), b)) }
            let negativePower = { (t: Term) in head(t) == "^" && looksNeg(arg(t, 2), loose: false) }
            if negativePower(a), !negativePower(b) {
                return try div(b, try normalize(.op("^", [arg(a, 1), try neg(arg(a, 2))])))
            }
            if negativePower(b), !negativePower(a) {
                return try div(a, try normalize(.op("^", [arg(b, 1), try neg(arg(b, 2))])))
            }
            if head(a) == "/" {
                if let c = try combineProd(arg(a, 2), b, invA: true, invB: false, scalarOkay: true) { return try mul(arg(a, 1), c) }
                return try div(try mul(arg(a, 1), b), arg(a, 2))
            }
            if head(b) == "/" { return try div(try mul(a, arg(b, 1)), arg(b, 2)) }
            if let f = head(b), f == "+" || f == "-", objectp(a), objectp(arg(b, 1)) || objectp(arg(b, 2)) {
                let (x, y) = (try mul(a, arg(b, 1)), try mul(a, arg(b, 2)))
                return f == "+" ? try add(x, y) : try sub(x, y)
            }
            if head(b) == "*", objectp(arg(b, 1)), !objectp(a) { return try mul(arg(b, 1), try mul(a, arg(b, 2))) }
            if looksNeg(b) || (head(b) == "-" && looksNeg(a)) { return try mul(try neg(a), try neg(b)) }
            if head(b) == "*" {
                if let c = try combineProd(a, arg(b, 1), invA: false, invB: false, scalarOkay: true) { return try mul(c, arg(b, 2)) }
            } else if let c = try combineProd(a, b, invA: false, invB: false, scalarOkay: false) {
                return c
            }
            for special in [nan, uinf] {
                if a == special { return a }
                if b == special { return b }
            }
            if b == inf {
                switch try signs(a) {
                case 4: return b
                case 1: return try neg(b)
                case 3, 6: throw Unsupported("symbolic arithmetic")
                default: break
                }
            }
            if a == inf { return try mul(b, a) }
            return .op("*", [a, b])
        }

        /// `math-div`.
        static func div(_ a: Term, _ b: Term) throws -> Term {
            if zerop(b) {
                // `math-div-by-zero`.
                guard let infinity = infinitep(a) else { throw Rejected() }
                return infinity == nan ? a : uinf
            }
            if let quotient = try numeric(a, b, { try divide($0, $1, fractions: fractions) }) { return quotient }
            // `math-div-zero`.
            if zerop(a) { return b == nan ? b : a }
            return try divFancy(a, b)
        }

        /// `math-div-symb-fancy`.
        static func divFancy(_ a: Term, _ b: Term) throws -> Term {
            if equalInt(b, 1) { return a }
            if equalInt(b, -1) { return try neg(a) }
            if head(b) == "^", looksNeg(arg(b, 2), loose: false) || equalInt(a, 1) {
                return try mul(a, try normalize(.op("^", [arg(b, 1), try neg(arg(b, 2))])))
            }
            if head(a) == "neg" { return try neg(try div(arg(a, 1), b)) }
            if head(b) == "neg" { return try neg(try div(a, arg(b, 1))) }
            if head(a) == "/" { return try div(arg(a, 1), try mul(arg(a, 2), b)) }
            if head(b) == "/" { return try div(try mul(a, arg(b, 2)), arg(b, 1)) }
            if case .number(.frac(let n, let d)) = b { return try mul(.number(try fraction(d, n)), a) }
            if let f = head(a), f == "+" || f == "-", objectp(arg(a, 1)) || objectp(arg(a, 2)), objectp(b) {
                let (x, y) = (try div(arg(a, 1), b), try div(arg(a, 2), b))
                return f == "+" ? try add(x, y) : try sub(x, y)
            }
            if head(a) == "-" || looksNeg(a), looksNeg(b) { return try div(try neg(a), try neg(b)) }
            if head(b) == "-", looksNeg(a) { return try div(try neg(a), try neg(b)) }
            if head(a) == "*" {
                if head(b) == "*" {
                    if let c = try combineProd(arg(a, 1), arg(b, 1), invA: false, invB: true, scalarOkay: true) {
                        return try div(try mul(c, arg(a, 2)), arg(b, 2))
                    }
                } else if let c = try combineProd(arg(a, 1), b, invA: false, invB: true, scalarOkay: true) {
                    return try mul(c, arg(a, 2))
                }
            } else if head(b) == "*" {
                if let c = try combineProd(a, arg(b, 1), invA: false, invB: true, scalarOkay: true) { return try div(c, arg(b, 2)) }
            } else if let c = try combineProd(a, b, invA: false, invB: true, scalarOkay: false) {
                return c
            }
            if infinitep(a) != nil {
                if infinitep(b) != nil { return nan }
                if a == nan || a == uinf { return a }
                if a == inf {
                    if posp(b) { return a }
                    if negp(b) { return try neg(a) }
                    if objectp(b) { throw Unsupported("symbolic arithmetic") }
                }
            }
            if infinitep(b) != nil {
                if b == nan { return b }
                return floatp(a) || floatp(b) ? .number(.float(0, 0)) : .number(.int(0))
            }
            return .op("/", [a, b])
        }

        /// `math-mul-or-div`.
        static func mulOrDiv(_ a: Term, _ b: Term, invA: Bool, invB: Bool) throws -> Term {
            if invA { return invB ? try div(try div(.number(.int(1)), a), b) : try div(b, a) }
            return invB ? try div(a, b) : try mul(a, b)
        }

        /// `math-combine-prod`: two factors that are powers of the same thing, multiplied.
        static func combineProd(_ a: Term, _ b: Term, invA: Bool, invB: Bool, scalarOkay: Bool) throws -> Term? {
            if (invA && zerop(a)) || (invB && zerop(b)) { return nil }
            if scalarOkay, objectp(a), objectp(b) {
                let r = try mulOrDiv(a, b, invA: invA, invB: invB)
                return objectp(r) ? r : nil
            }
            if head(a) == "^", invA, looksNeg(arg(a, 2)) { return try mul(try pow(arg(a, 1), try neg(arg(a, 2))), b) }
            if head(b) == "^", invB, looksNeg(arg(b, 2)) { return try mul(a, try pow(arg(b, 1), try neg(arg(b, 2)))) }
            func split(_ t: Term) throws -> (Term, Term) {
                var (base, power) = (t, Term.number(.int(1)))
                if head(t) == "^", objectp(arg(t, 2)) { (base, power) = (arg(t, 1), arg(t, 2)) }
                if head(t) == "sqrt" { (base, power) = (arg(t, 1), .number(.frac(1, 2))) }
                // Only in symbolic mode does `exp` of a number stay.
                if head(t) == "exp", objectp(arg(t, 1)) { throw Unsupported("symbolic arithmetic") }
                if case .number(.frac(let n, let d)) = base, n < d {
                    (base, power) = (try div(.number(.int(1)), base), try neg(power))
                }
                return (base, power)
            }
            var (baseA, powA) = try split(a)
            var (baseB, powB) = try split(b)
            if invA { powA = try neg(powA) }
            if invB { powB = try neg(powB) }
            func isFrac(_ t: Term) -> Bool {
                if case .number(.frac) = t { return true }
                return false
            }
            if baseA == baseB {
                var sum = try add(powA, powB)
                if !integerp(baseA) || zerop(sum) || isFrac(powA) == isFrac(powB) {
                    if looksNeg(sum), ratp(baseA), posp(baseA) {
                        (baseA, sum) = (try div(.number(.int(1)), baseA), try neg(sum))
                    }
                    return try root(baseA, sum)
                }
            }
            if powA == powB, case .number(.int(let x)) = baseA, case .number(.int(let y)) = baseB, x >= 0, y >= 0 {
                return try root(try mul(baseA, baseB), powA)
            }
            return nil
        }

        /// `a^p`, with Calc's square root form for a half.
        static func root(_ a: Term, _ p: Term) throws -> Term {
            if p == .number(.frac(1, 2)) { return .op("sqrt", [a]) }
            if p == .number(.frac(-1, 2)) { return try div(.number(.int(1)), .op("sqrt", [a])) }
            return try pow(a, p)
        }

        /// `math-pow`.
        static func pow(_ a: Term, _ b: Term) throws -> Term {
            if b == nan { return b }
            if zerop(a) {
                if let y = number(b) {
                    if try sign(y) > 0 { return floatp(b) ? try float(a) : a }
                    return .number(try power(number(a)!, y, fractions: fractions))
                }
                // `math-pow-of-zero` with a formula.
                switch try signs(b) {
                case 4: return a
                case 1: return try div(.number(.int(1)), a)
                default: return infinitep(b) != nil ? nan : .op("^", [a, b])
                }
            }
            if a == .number(.int(1)) || b == .number(.int(1)) { return a }
            if a == .number(.float(1, 0)) || b == .number(.float(1, 0)) { return a }
            if zerop(b) {
                if let x = number(a) { return .number(try power(x, number(b)!, fractions: fractions)) }
                // `math-pow-zero`.
                if infinitep(a) != nil { return nan }
                return floatp(b) ? .number(.float(1, 0)) : .number(.int(1))
            }
            if let x = number(a), let y = number(b) { return .number(try power(x, y, fractions: fractions)) }
            return try powFancy(a, b)
        }

        /// `math-pow-fancy` with a formula.
        static func powFancy(_ a: Term, _ b: Term) throws -> Term {
            let (a1, a2) = (arg(a, 1), arg(a, 2))
            switch head(a) {
            case "*" where try knownNumInteger(b) || knownNonneg(a1) || knownNonneg(a2):
                return try mul(try pow(a1, b), try pow(a2, b))
            case "/" where try knownNumInteger(b) || knownNonneg(a2):
                return try div(try pow(a1, b), try pow(a2, b))
            case "/" where try knownNonneg(a1) && !equalInt(a1, 1):
                return try mul(try pow(a1, b), try pow(try div(.number(.int(1)), a2), b))
            case "^" where try knownNumInteger(b) || knownNonneg(a1):
                return try pow(a1, try mul(a2, b))
            case "sqrt" where try knownNumInteger(b) || knownNonneg(a1):
                return try pow(a1, try div(b, .number(.int(2))))
            case "^":
                if let y = number(b), let q = quarter(y), (1...3).contains(q), try knownEven(a2), try knownReal(a1) {
                    return try absTerm(try pow(a1, try mul(a2, b)))
                }
            default: break
            }
            if looksNeg(a), case .number(.int(let n)) = b {
                let p = try pow(try neg(a), b)
                return n % 2 == 0 ? p : try neg(p)
            }
            if head(a) == "abs", try knownReal(a1), try knownEven(b) { return try pow(a1, b) }
            if let infinity = infinitep(a) {
                if infinity == nan { return infinity }
                if head(a) == "neg" { return try mul(try pow(.number(.int(-1)), b), try pow(a1, b)) }
                if posp(b) { return a }
                if negp(b) { return floatp(b) ? .number(.float(0, 0)) : .number(.int(0)) }
                if objectp(b) || infinitep(b) != nil { return nan }
                throw Unsupported("symbolic arithmetic")
            }
            if infinitep(b) != nil {
                guard let x = number(a), b == inf else { throw Unsupported("symbolic arithmetic") }
                // `calcFunc-abssqr` of a real number is its square.
                let scale = try multiply(x, x)
                if scale == .int(1) || scale == .float(1, 0) { return nan }
                if try compare(scale, .int(1)) < 0 { return floatp(a) ? .number(.float(0, 0)) : .number(.int(0)) }
                if try compare(.int(1), x) < 0 { return b }
                return uinf
            }
            return .op("^", [a, b])
        }

        // MARK: Functions

        /// The functions `function` applies to formulas; `%` is `math-mod`.
        static let functions: Set<String> = ["sqrt", "abs", "exp", "ln", "min", "max", "eq", "neq", "lt", "gt", "leq", "geq",
                                             "land", "lor", "lnot", "%"]

        /// `name` of `args`, at least one a formula, as `math-normalize` calls it: simplified,
        /// or kept with its arguments when the function rejects them.
        static func function(_ name: String, _ args: [Term]) throws -> Term {
            do { return try simplify(name, args) } catch is Rejected { return .op(name, args) }
        }

        static func simplify(_ name: String, _ args: [Term]) throws -> Term {
            let kept = Term.op(name, args)
            switch (name, args.count) {
            case ("sqrt", 1), ("exp", 1), ("ln", 1):
                // In symbolic mode these keep a result that isn't exact, which isn't reproduced.
                guard !symbolicMode else { throw Unsupported("function \(name) in symbolic mode") }
                switch name {
                case "sqrt": return try sqrtTerm(args[0])
                case "exp": return try expTerm(args[0])
                default: return try lnTerm(args[0])
                }
            case ("abs", 1): return try absTerm(args[0])
            case ("min", _), ("max", _):
                // `calcFunc-min` rejects an argument that isn't a real number or an infinity.
                guard !args.isEmpty else { throw Unsupported("arguments") }
                guard args.allSatisfy({ objectp($0) || infinitep($0) != nil }) else { return kept }
                return try args.dropFirst().reduce(args[0]) { best, item in
                    switch try compareTerms(best, item) {
                    case 2: return nan
                    case let order: return order == (name == "max" ? -1 : 1) ? item : best
                    }
                }
            case ("eq", 2), ("neq", 2), ("lt", 2), ("gt", 2), ("leq", 2), ("geq", 2):
                let (a, b) = (args[0], args[1])
                let order = try compareTerms(a, b)
                if order == 2 {
                    // Both sides negative, or zero, flip.
                    if looksNeg(a) || zerop(a), looksNeg(b) || zerop(b) {
                        return .op(flipped[name]!, [try neg(a), try neg(b)])
                    }
                    return kept
                }
                let holds = switch name {
                case "eq": order == 0
                case "neq": order != 0
                case "lt": order == -1
                case "gt": order == 1
                case "leq": order != 1
                default: order != -1
                }
                return .number(.int(holds ? 1 : 0))
            case ("land", 2):
                let (a, b) = (args[0], args[1])
                if zerop(a) { return a }
                if zerop(b) { return b }
                if try isTrue(a) { return b }
                if try isTrue(b) { return a }
                return kept
            case ("lor", 2):
                let (a, b) = (args[0], args[1])
                if zerop(a) { return b }
                if zerop(b) { return a }
                if try isTrue(a) { return a }
                if try isTrue(b) { return b }
                return kept
            case ("lnot", 1):
                let a = args[0]
                if zerop(a) { return .number(.int(1)) }
                if try isTrue(a) { return .number(.int(0)) }
                if case .op(let f, let xs) = a, xs.count == 2, let opposite = negated[f] { return .op(opposite, xs) }
                return kept
            case ("%", 2): return try modTerm(args[0], args[1])
            default: throw Unsupported("function \(name) of a formula")
            }
        }

        /// The comparison with its sides negated, and its negation (`calc-tweak-eqn-table`).
        static let flipped = ["eq": "eq", "neq": "neq", "lt": "gt", "gt": "lt", "leq": "geq", "geq": "leq"]
        static let negated = ["eq": "neq", "neq": "eq", "lt": "geq", "gt": "leq", "leq": "gt", "geq": "lt"]

        /// `math-is-true`.
        static func isTrue(_ t: Term) throws -> Bool {
            if let v = number(t) { return !isZero(v) }
            return [1, 4, 5, 8, 9, 12, 13].contains(try signs(t))
        }

        /// `math-compare`: -1, 0 or 1, or 2 when the order isn't known.
        static func compareTerms(_ a: Term, _ b: Term) throws -> Int {
            if a == b {
                switch a {
                case .number: return 0
                case .variable, .op("neg", _), .op("*", _), .op("/", _): return infinitep(a) != nil ? 2 : 0
                default: return 0
                }
            }
            if let x = number(a), let y = number(b) { return try Calc.compare(x, y) }
            if case .number(.frac(let n, let d)) = a { return try compareTerms(.number(.int(n)), try mul(b, .number(.int(d)))) }
            if case .number(.frac(let n, let d)) = b { return try compareTerms(try mul(a, .number(.int(d))), .number(.int(n))) }
            let one = Term.number(.int(1)), minusOne = Term.number(.int(-1))
            if let infA = infinitep(a) {
                if a == uinf || a == nan { return 2 }
                let dirA = try infiniteDirection(a, infA)
                if let infB = infinitep(b) {
                    if b == uinf || b == nan { return 2 }
                    let dirB = try infiniteDirection(b, infB)
                    return dirA == one && dirB == minusOne ? 1 : dirA == minusOne && dirB == one ? -1 : 2
                }
                return dirA == one ? 1 : dirA == minusOne ? -1 : 2
            }
            if let infB = infinitep(b) {
                if b == uinf || b == nan { return 2 }
                let dirB = try infiniteDirection(b, infB)
                return dirB == one ? -1 : dirB == minusOne ? 1 : 2
            }
            let e = Term.variable("e")
            if head(a) == "exp", head(b) == "^", arg(b, 1) == e { return try compareTerms(arg(a, 1), arg(b, 2)) }
            if head(b) == "exp", head(a) == "^", arg(a, 1) == e { return try compareTerms(arg(a, 2), arg(b, 1)) }
            let half: [Term] = [.number(.frac(1, 2)), .number(.float(5, -1))]
            if (head(a) == "sqrt" && head(b) == "^" && half.contains(arg(b, 2)))
                || (head(b) == "sqrt" && head(a) == "^" && half.contains(arg(a, 2))) {
                return try compareTerms(arg(a, 1), arg(b, 1))
            }
            if case .variable = a { return 2 }
            if case .op(let f, let xs) = a, case .op(let g, let ys) = b, f == g, xs.count == ys.count,
               try zip(xs, ys).allSatisfy({ try compareTerms($0, $1) == 0 }) { return 0 }
            return 2
        }

        /// `math-sqrt` of a formula.
        static func sqrtTerm(_ a: Term) throws -> Term {
            if let v = number(a) { return .number(try squareRoot(v)) }
            // An imaginary result.
            if [1, 2, 3].contains(try signs(a)) { throw Unsupported("complex result") }
            let (a1, a2) = (arg(a, 1), arg(a, 2))
            switch head(a) {
            case "*" where try knownNonneg(a1) || knownNonneg(a2):
                return try mul(try sqrtTerm(a1), try sqrtTerm(a2))
            case "/" where try knownNonneg(a2):
                return try div(try sqrtTerm(a1), try sqrtTerm(a2))
            case "/" where try knownNonneg(a1) && !equalInt(a1, 1):
                return try mul(try sqrtTerm(a1), try sqrtTerm(try div(.number(.int(1)), a2)))
            case "^" where try knownEven(a2) && knownReal(a1):
                return try absTerm(try pow(a1, try div(a2, .number(.int(2)))))
            default: break
            }
            if let infinity = infinitep(a) { return try mul(try sqrtTerm(try infiniteDirection(a, infinity)), infinity) }
            return .op("sqrt", [a])
        }

        /// `math-abs` of a formula.
        static func absTerm(_ a: Term) throws -> Term {
            if let v = number(a) { return .number(try absolute(v)) }
            if negp(a) { return try neg(a) }
            if looksNeg(a) { return .op("abs", [try neg(a)]) }
            let s = try signs(a)
            if [2, 4, 6].contains(s) { return a }
            if [1, 3].contains(s) { return try neg(a) }
            if let infinity = infinitep(a) { return infinity == nan ? nan : inf }
            return .op("abs", [a])
        }

        /// `calcFunc-exp` of a formula.
        static func expTerm(_ a: Term) throws -> Term {
            if objectp(a) { throw Unsupported("symbolic arithmetic") }
            if a == inf || a == nan { return a }
            if a == .op("neg", [inf]) { return .number(.int(0)) }
            return .op("exp", [a])
        }

        /// `calcFunc-ln` of a formula.
        static func lnTerm(_ a: Term) throws -> Term {
            if objectp(a) { throw Unsupported("symbolic arithmetic") }
            if a == .variable("e") { return .number(.int(1)) }
            if head(a) == "^", arg(a, 1) == .variable("e"), try knownReal(arg(a, 2)) { return arg(a, 2) }
            if infinitep(a) != nil { return a == nan ? nan : inf }
            return .op("ln", [a])
        }

        /// `math-mod` with a formula.
        static func modTerm(_ a: Term, _ b: Term) throws -> Term {
            if zerop(a) { return a }
            if objectp(a), objectp(b) { throw Unsupported("symbolic arithmetic") }
            if b == inf {
                if posp(a) || zerop(a) { return a }
                if negp(a) { return b }
            }
            return .op("%", [a, b])
        }

        // MARK: Display

        /// `math-format-value`: `math-compose-expr` in the flat language.
        static func format(_ t: Term, _ floatFormat: FloatFormat) throws -> String {
            let text = try compose(t, 0, floatFormat)
            // Past its width of 1000, `calc-eval` breaks the line.
            guard text.count < 1000 else { throw Unsupported("symbolic arithmetic") }
            return text
        }

        /// Left and right precedence, from `math-standard-ops` with
        /// `calc-multiplication-has-precedence`.
        static let operators: [String: (Int, Int)] = ["+": (180, 181), "-": (180, 181), "*": (196, 195), "/": (190, 191), "^": (201, 200),
                                                      "%": (190, 191), "eq": (160, 161), "neq": (160, 161), "lt": (160, 161),
                                                      "gt": (160, 161), "leq": (160, 161), "geq": (160, 161), "land": (110, 111),
                                                      "lor": (100, 101)]

        static let symbols = ["eq": "=", "neq": "!=", "lt": "<", "gt": ">", "leq": "<=", "geq": ">=", "land": "&&", "lor": "||"]

        static func compose(_ t: Term, _ prec: Int, _ floatFormat: FloatFormat, div: Bool = false) throws -> String {
            switch t {
            case .number(let v): return try Calc.format(v, floatFormat)
            case .variable(let name): return name
            case .op("neg", let args):
                if prec > 197 { return "(" + (try compose(t, 0, floatFormat)) + ")" }
                return "-" + (try compose(args[0], 197, floatFormat))
            case .op("lnot", let args) where args.count == 1:
                if prec > 1000 { return "(" + (try compose(t, 0, floatFormat)) + ")" }
                return "!" + (try compose(args[0], 1000, floatFormat))
            case .op("if", let args) where args.count == 3:
                if prec > 90 { return "(" + (try compose(t, 0, floatFormat)) + ")" }
                return try compose(args[0], 91, floatFormat) + " ? " + compose(args[1], 0, floatFormat) + " : "
                    + compose(args[2], 90, floatFormat)
            case .op(let f, let args):
                guard let (left, right) = operators[f], args.count == 2 else {
                    return f + "(" + (try args.map { try compose($0, 0, floatFormat) }).joined(separator: ", ") + ")"
                }
                if prec > min(left, right) || (div && f == "*") { return "(" + (try compose(t, 0, floatFormat)) + ")" }
                var lhs = try compose(args[0], left, floatFormat)
                let rhs = try compose(args[1], right, floatFormat, div: f == "/")
                if f == "^", lhs.first == "-" { lhs = "(" + lhs + ")" }
                if f == "*", let next = rhs.first {
                    var lastFactor = args[0]
                    while head(lastFactor) == "*" { lastFactor = arg(lastFactor, 2) }
                    let isVariable = if case .variable = lastFactor { true } else { false }
                    if (next.isASCII && (next.isLetter || next.isNumber)) || ".#_([{".contains(next), !(isVariable && next == "(") {
                        return lhs + " " + rhs
                    }
                    return lhs + "*" + rhs
                }
                if f == "^" { return lhs + "^" + rhs }
                if f == "/", let x = number(args[0]), isWhole(x), case .number(.int) = args[1] { return lhs + "/" + rhs }
                return lhs + " " + (symbols[f] ?? f) + " " + rhs
            }
        }
    }
}
