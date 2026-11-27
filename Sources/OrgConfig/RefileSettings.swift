import Foundation
import OrgCore

/// `org-refile-targets`, `org-refile-use-outline-path` and
/// `org-refile-allow-creating-parent-nodes` (Org 9.8.7).
public struct RefileSettings: Sendable, Equatable {
    /// Where an `org-refile-targets` entry looks.
    public enum Files: Sendable, Equatable {
        /// `nil`: the file refiled from.
        case current
        case agendaFiles
        case paths([String])
        /// Every org file in the folders: orgstar's default.
        case workspace
    }

    /// Which headings an entry offers.
    public enum Spec: Sendable, Equatable {
        /// `t`: every heading.
        case all
        case tag(String), todo(String)
        /// An Emacs regexp.
        case regexp(String)
        case level(Int), maxLevel(Int)
    }

    public struct Target: Sendable, Equatable {
        public var files: Files
        public var spec: Spec

        public init(files: Files, spec: Spec) {
            self.files = files
            self.spec = spec
        }
    }

    public enum OutlinePath: String, Sendable, CaseIterable {
        case none = "nil", full = "t", file, fullFilePath = "full-file-path", bufferName = "buffer-name", title
    }

    public enum Creating: String, Sendable, CaseIterable {
        case no = "nil", yes = "t", confirm
    }

    public enum Failure: Error, Equatable {
        case message(String)
    }

    public var targets: [Target]
    public var outlinePath: OutlinePath
    public var creating: Creating

    /// Headings down to level 3 in every file, as orgstar offers with no `org-refile-targets`.
    public static let workspaceTargets = [Target(files: .workspace, spec: .maxLevel(3))]

    public init(targets: [Target] = workspaceTargets, outlinePath: OutlinePath = .file, creating: Creating = .no) {
        self.targets = targets
        self.outlinePath = outlinePath
        self.creating = creating
    }

    /// An `org-refile-targets` value as Lisp writes it: `((nil :maxlevel . 3)
    /// (org-agenda-files :tag . "project") ("~/notes/x.org" :level . 1))`. Empty text is
    /// orgstar's default.
    public static func parseTargets(_ text: String) -> Result<[Target], Failure> {
        guard text.contains(where: { !$0.isWhitespace }) else { return .success(workspaceTargets) }
        let value: Sexp
        do {
            guard let form = try LispReader.read(text).first?.sexp else { return .success(workspaceTargets) }
            value = form
        } catch {
            return .failure(.message("can't read \(text)"))
        }
        func unquote(_ s: Sexp) -> Sexp {
            if case .list(let items) = s, items.count == 2, items[0].symbol == "quote" { return items[1] }
            return s
        }
        guard let entries = unquote(value).elements else { return .failure(.message("not a list of targets")) }
        var targets: [Target] = []
        for entry in entries {
            // `(FILES . (KEY . VALUE))`, read as `(FILES KEY . VALUE)`, or `(FILES KEY VALUE)`.
            let head: Sexp
            var key: String?
            var argument: Sexp?
            switch entry {
            case .dotted(let items, let last) where items.count == 2:
                head = items[0]
                key = items[1].symbol
                argument = last
            case .list(let items) where items.count == 3:
                head = items[0]
                key = items[1].symbol
                argument = items[2]
            case .dotted(let items, let last) where items.count == 1 && last.symbol == "t":
                head = items[0]
                key = "t"
            default:
                return .failure(.message("\(entry.description) isn't a target"))
            }
            let files: Files
            switch head {
            case .symbol("nil"): files = .current
            case .symbol("org-agenda-files"): files = .agendaFiles
            case .string(let path): files = .paths([path])
            case .list(let items) where items.allSatisfy({ $0.string != nil }): files = .paths(items.compactMap(\.string))
            default: return .failure(.message("files \(head.description) aren't supported"))
            }
            let spec: Spec
            switch (key, argument) {
            case ("t"?, _): spec = .all
            case (":tag"?, .string(let s)?): spec = .tag(s)
            case (":todo"?, .string(let s)?): spec = .todo(s)
            case (":regexp"?, .string(let s)?): spec = .regexp(s)
            case (":level"?, .integer(let n)?): spec = .level(n)
            case (":maxlevel"?, .integer(let n)?): spec = .maxLevel(n)
            default: return .failure(.message("\(entry.description) isn't a target"))
            }
            targets.append(Target(files: files, spec: spec))
        }
        return .success(targets)
    }

    /// `org-refile-get-targets`'s `descre` for `spec`, in Emacs syntax.
    public static func regexp(_ spec: Spec) -> String {
        func quote(_ s: String) -> String { s.map { "[*.\\?+^$".contains($0) ? "\\" + String($0) : String($0) }.joined() }
        switch spec {
        case .all: return "^\\*+[ \t]"
        case .tag(let tag): return "^\\*+[ \t]+.*?:" + quote(tag) + ":"
        case .todo(let keyword): return "^\\*+[ \t]+" + quote(keyword) + "[ \t]"
        case .regexp(let re): return re
        case .level(let n): return "^\\*\\{\(n)\\}[ \t]"
        case .maxLevel(let n): return "^\\*\\{1,\(n)\\}[ \t]"
        }
    }
}
