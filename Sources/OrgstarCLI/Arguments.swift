/// A command's words after its name: positional arguments, flags, and options with a value,
/// as `--name value` or `--name=value`. `--` ends the options.
struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: [String]] = [:]

    /// `aliases` maps short names, such as `-o`, to long ones.
    init(_ words: [String], command: String, flags known: Set<String>, options takes: Set<String> = [], aliases: [String: String] = [:]) throws(Failure) {
        var rest = words[...]
        while let word = rest.popFirst() {
            if word == "--" {
                positional += rest
                break
            }
            guard word.hasPrefix("-"), word != "-" else {
                positional.append(word)
                continue
            }
            var name = word
            var value: String?
            if let equals = word.firstIndex(of: "="), word.hasPrefix("--") {
                name = String(word[..<equals])
                value = String(word[word.index(after: equals)...])
            }
            name = aliases[name] ?? name
            if known.contains(name), value == nil {
                flags.insert(name)
            } else if takes.contains(name) {
                guard let given = value ?? rest.popFirst() else { throw Failure(.usage, "\(command): \(name) needs a value") }
                options[name, default: []].append(given)
            } else {
                throw Failure(.usage, "\(command): unknown option \(word)")
            }
        }
    }

    func value(_ name: String) -> String? { options[name]?.last }

    /// Throws unless there are between `min` and `max` positional arguments.
    func expect(_ min: Int, _ max: Int, _ command: String) throws(Failure) {
        if positional.count < min { throw Failure(.usage, "\(command): missing argument; see orgstar \(command) --help") }
        if positional.count > max { throw Failure(.usage, "\(command): unexpected argument \(positional[max])") }
    }
}
