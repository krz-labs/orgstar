import Foundation

// ob-calc (Org 9.8.7) on `Calc`: each line of the body goes onto a fresh Calc stack, as in a
// new Emacs, and the value is the top of the stack. Calc's own modes apply, not
// `org-calc-default-modes`: 12 digits shown in full.

extension Babel {
    /// A calc block: its lines, trimmed, and its variables as Calc values.
    public struct CalcBlock: Sendable, Equatable {
        let lines: [String]
        let vars: [Variable]
        /// `org-babel-result-cond` takes the value as a string.
        let scalar: Bool
        /// Why the block can't run here, found when it was planned.
        let refusal: Calc.Unsupported?

        struct Variable: Sendable, Equatable {
            let name: String
            let value: Calc.Value
        }
    }

    /// `org-babel-execute:calc` with `emacs -Q` modes.
    static let calcModes: Calc.Modes = {
        var modes = Calc.Modes()
        modes.format = .float(0)
        return modes
    }()

    /// Plans a calc block: natively through `job.calc`, and in Emacs through `job.input`.
    static func calcJob(body: String, vars: [(String, VarValue)], params: Params, finish: BabelJob.Finish, directory: String?,
                        block: Range<Int>, blockText: String, alwaysAsk: Bool) throws -> BabelJob {
        let prologue = params.single[":prologue"], epilogue = params.single[":epilogue"]
        let expanded = (prologue.map { $0 + "\n" } ?? "") + body + (epilogue.map { "\n" + $0 + "\n" } ?? "")
        var job = BabelJob(language: "calc", runner: .emacs, input: calcScript(body: body, vars: vars, params: params, finish: finish),
                           directory: directory, block: block, blockText: blockText, alwaysAsk: alwaysAsk, finish: finish)
        let lines = expanded.components(separatedBy: CharacterSet(charactersIn: "\n\r")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var values: [CalcBlock.Variable] = []
        var refusal: Calc.Unsupported?
        do {
            // `org-babel-read` makes a number of an unquoted `:prologue 2`, which `concat` refuses.
            if [":prologue", ":epilogue"].contains(where: { key in params.single[key].map { !params.quoted.contains(key) && number($0) != nil } ?? false }) {
                throw Calc.Unsupported("numeric :prologue or :epilogue")
            }
            values = try vars.map { try CalcBlock.Variable(name: $0.0, value: calcValue($0.1, name: $0.0)) }
        } catch let error as Calc.Unsupported {
            refusal = error
        }
        job.calc = CalcBlock(lines: lines, vars: values, scalar: resultCondScalar(finish.params), refusal: refusal)
        return job
    }

    /// `org-babel-result-cond`: whether the value is taken as a string.
    static func resultCondScalar(_ params: [String]) -> Bool {
        params.contains("scalar") || params.contains("verbatim") || params.contains("html") || params.contains("code")
            || params.contains("pp") || params.contains("file")
            || ((params.contains("output") || params.contains("raw") || params.contains("org")) && !params.contains("table"))
    }

    /// A `:var` value as ob-calc pushes it: a number read by Calc, a list as a vector, a table as
    /// a matrix (one row as a vector). Strings, Lisp floats inside lists, and names Calc reads as
    /// something else are refused.
    static func calcValue(_ value: VarValue, name: String) throws -> Calc.Value {
        let refusal = Calc.Unsupported("value of :var \(name)")
        guard name.range(of: "^[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) != nil, !Calc.constants.contains(name), !Calc.reserved.contains(name) else { throw refusal }
        func integer(_ cell: Cell) throws -> Calc.Value {
            guard case .number(let n) = cell, let i = Int(n) else { throw refusal }
            return .int(i)
        }
        switch value {
        case .number(let n):
            return try Calc.withModes(calcModes) {
                var parser = Calc.Parser(n.replacingOccurrences(of: "e+", with: "e"))
                return try Calc.Evaluator(modes: calcModes).eval(try parser.parse())
            }
        case .list(let items) where items.count > 1:
            return .vector(try items.map(integer))
        case .table(let rows) where !rows.isEmpty && !rows.contains(where: { $0 == nil || $0!.isEmpty }):
            let matrix = try rows.map { try $0!.map(integer) }
            return matrix.count == 1 ? .vector(matrix[0]) : .vector(matrix.map { .vector($0) })
        default:
            throw refusal
        }
    }

    /// Runs `job.calc` as ob-calc does: the output `calcScript` prints. Throws `Calc.Unsupported`
    /// for what Calc here doesn't do as Emacs's does, and `Failure` for Emacs's errors.
    public static func evaluateCalc(_ job: BabelJob) throws -> BabelOutput {
        guard let block = job.calc else { throw Failure.message("Not a calc block.") }
        if let refusal = block.refusal { throw refusal }
        do {
            return try calc(block)
        } catch let error as Calc.Failure {
            // `math-read-number` of the error `calc-eval` returns.
            throw Failure.message("Wrong type argument: stringp, (\(error.position) \"\(error.reason)\")")
        }
    }

    static func calc(_ block: CalcBlock) throws -> BabelOutput {
        try Calc.withModes(calcModes) {
            let evaluator = Calc.Evaluator(modes: calcModes)
            let names = Set(block.vars.map(\.name))
            var stored: [String: Calc.Value] = [:]
            for variable in block.vars { stored[variable.name] = variable.value }
            /// Stack entries: a number, or the string ob-calc pushes for any other value.
            /// `known` is false when Calc here couldn't tell whether ob-calc pushed a number.
            enum Entry { case number(Calc.Value), text(String, known: Bool) }
            var stack: [Entry] = []
            func pop() throws -> Calc.Value {
                guard let top = stack.popLast() else { throw Failure.message("Too few elements on stack") }
                switch top {
                case .number(let v): return v
                case .text(_, true): throw Failure.message("Invalid data object encountered")
                case .text(_, false): throw Calc.Unsupported("symbolic arithmetic")
                }
            }
            for line in block.lines where !line.isEmpty {
                if names.contains(line) {
                    stack.append(.number(stored[line]!))
                } else if line.hasPrefix("'") {
                    let key = String(line.dropFirst())
                    let node: Calc.Node
                    switch key {
                    case "+", "-", "*", "/", "^", "%", "\\":
                        guard stack.count >= 2 else { throw Failure.message("Too few elements on stack") }
                        let b = try pop(), a = try pop()
                        node = .binary(Character(key), .number(a), .number(b))
                    case "n": node = .unary("-", .number(try pop()))
                    case "&": node = .binary("/", .number(.int(1)), .number(try pop()))
                    case "Q": node = .call("sqrt", [.number(try pop())])
                    case "A": node = .call("abs", [.number(try pop())])
                    default: throw Calc.Unsupported("stack command '\(key)")
                    }
                    stack.append(.number(try checked(try evaluator.eval(node))))
                } else {
                    var parser = Calc.Parser(line)
                    let tree = try parser.parse()
                    // `calc-eval` of the line: a number is pushed as one.
                    let first: Calc.Value?
                    do {
                        first = try checked(try evaluator.eval(tree))
                    } catch is Calc.Unsupported where !tree.variables.isDisjoint(with: names) {
                        // Calc here can't keep this formula of the block's variables, which
                        // Emacs's Calc keeps as a formula unless it simplifies to a number.
                        first = nil
                    }
                    if let first, isNumber(first) {
                        stack.append(.number(first))
                    } else {
                        // The formula again with the block's variables put in, as text.
                        let resolved = try checked(try evaluator.eval(tree.substituting(stored)))
                        let text = try Calc.format(resolved, calcModes.format).replacingOccurrences(of: "'", with: "")
                        stack.append(.text(text, known: first != nil))
                    }
                }
            }
            guard let top = stack.last else { throw Failure.message("Too few elements on stack") }
            let result: Calc.Value
            switch top {
            case .number(let v): result = v
            case .text(let s, _):
                var parser = Calc.Parser(s)
                result = try checked(try evaluator.eval(try parser.parse()))
            }
            let object: [String: Any]
            if case .vector(let items) = result, !block.scalar {
                let rows: [[Calc.Value]]
                if case .vector(let first)? = items.first, !first.isEmpty,
                   items.allSatisfy({ if case .vector(let row) = $0 { row.count == first.count } else { false } }) {
                    rows = items.map { if case .vector(let row) = $0 { row } else { [] } }
                } else {
                    rows = [items]
                }
                guard !rows.contains(where: \.isEmpty) else { throw Calc.Unsupported("empty vector") }
                object = ["rows": try rows.map { try $0.map { try Calc.format($0, calcModes.format) } }]
            } else {
                object = ["value": try Calc.format(result, calcModes.format)]
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            return BabelOutput(stdout: String(decoding: data, as: UTF8.self))
        }
    }

    static func isNumber(_ value: Calc.Value) -> Bool {
        switch value {
        case .int, .float, .frac: true
        default: false
        }
    }

    /// Dates show in Calc's own format, not Org's.
    static func checked(_ value: Calc.Value) throws -> Calc.Value {
        func hasDate(_ v: Calc.Value) -> Bool {
            switch v {
            case .date: true
            case .vector(let items): items.contains(where: hasDate)
            default: false
            }
        }
        if hasDate(value) { throw Calc.Unsupported("dates in calc blocks") }
        return value
    }

    /// Emacs running `org-babel-execute:calc` on the block, printing the value as JSON.
    static func calcScript(body: String, vars: [(String, VarValue)], params: Params, finish: BabelJob.Finish) -> String {
        var entries = vars.map { "(:var . (\($0.0) . \(lispLiteral($0.1))))" }
        for key in [":prologue", ":epilogue"] {
            if let value = params.single[key] {
                entries.append("(\(key) . \(!params.quoted.contains(key) && number(value) != nil ? value : lispString(value)))")
            }
        }
        entries.append("(:result-params . (" + finish.params.map { lispString($0) }.joined(separator: " ") + "))")
        return """
            ;;; -*- lexical-binding: t -*-
            (require 'ob-calc)
            (require 'json)
            (condition-case err
                (let* ((inhibit-message t)
                       (result (org-babel-execute:calc \(lispString(body)) '(\(entries.joined(separator: " "))))))
                  (princ (json-encode
                          (if (listp result)
                              `((rows . ,(vconcat (mapcar (lambda (row) (vconcat (mapcar (lambda (c) (format "%s" c)) row))) result))))
                            `((value . ,(format "%s" result)))))))
              (error (let ((inhibit-message nil)) (message "%s" (error-message-string err)))
                     (kill-emacs 1)))
            """
    }
}

extension Calc {
    /// `body` with `modes`' precision, fractions and symbolic mode.
    static func withModes<T>(_ modes: Modes, _ body: () throws -> T) throws -> T {
        guard (3...18).contains(modes.precision) else { throw Unsupported("calc precision") }
        return try $precision.withValue(modes.precision) {
            try $fractions.withValue(modes.preferFractions) {
                try $symbolicMode.withValue(modes.symbolic, operation: body)
            }
        }
    }
}

extension Calc.Node {
    /// `org-babel-calc-maybe-resolve-var`: the variables in `values` replaced by their values.
    func substituting(_ values: [String: Calc.Value]) -> Calc.Node {
        switch self {
        case .number: self
        case .variable(let name): values[name].map(Calc.Node.number) ?? self
        case .vector(let items): .vector(items.map { $0.substituting(values) })
        case .unary(let op, let a): .unary(op, a.substituting(values))
        case .binary(let op, let a, let b): .binary(op, a.substituting(values), b.substituting(values))
        case .call(let name, let args): .call(name, args.map { $0.substituting(values) })
        }
    }
}
