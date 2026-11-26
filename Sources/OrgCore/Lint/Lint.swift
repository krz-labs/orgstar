import Foundation

/// How sure a checker is that what it reports is a mistake, as org-lint's `:trust`.
public enum LintTrust: String, Sendable {
    case high, low
}

/// The checks Lint File runs. A checker with org-lint's name reports what org-lint's checker of
/// that name reports (`org-lint.el`, Org 9.8.7), with the same trust; the others are orgstar's.
public enum LintChecker: String, CaseIterable, Sendable {
    // Links.
    case invalidFuzzyLink = "invalid-fuzzy-link"
    case invalidCustomIDLink = "invalid-custom-id-link"
    case invalidIDLink = "invalid-id-link"
    case invalidCoderefLink = "invalid-coderef-link"
    case linkToLocalFile = "link-to-local-file"
    case invalidFileSearch = "invalid-file-search"
    case fileApplication = "file-application"
    // Attachments.
    case missingAttachmentFolder = "missing-attachment-folder"
    case orphanedAttachmentFolder = "orphaned-attachment-folder"
    // Duplicates.
    case duplicateID = "duplicate-id"
    case duplicateCustomID = "duplicate-custom-id"
    case duplicateName = "duplicate-name"
    case duplicateTarget = "duplicate-target"
    case duplicateFootnoteDefinition = "duplicate-footnote-definition"
    // Structure.
    case incompleteDrawer = "incomplete-drawer"
    case invalidBlock = "invalid-block"
    case misplacedPlanningInfo = "misplaced-planning-info"
    case obsoletePropertiesDrawer = "obsolete-properties-drawer"
    case misplacedHeading = "misplaced-heading"
    case indentedDiarySexp = "indented-diary-sexp"
    case invalidKeywordSyntax = "invalid-keyword-syntax"
    case orphanedAffiliatedKeywords = "orphaned-affiliated-keywords"
    case obsoleteAffiliatedKeywords = "obsolete-affiliated-keywords"
    case missingLanguageInSrcBlock = "missing-language-in-src-block"
    case missingBackendInExportBlock = "missing-backend-in-export-block"
    case deprecatedExportBlocks = "deprecated-export-blocks"
    case deprecatedCategorySetup = "deprecated-category-setup"
    case nonExistentSetupfileParameter = "non-existent-setupfile-parameter"
    // Headings and properties.
    case unknownTodoKeyword = "unknown-todo-keyword"
    case priority
    case spuriousColons = "spurious-colons"
    case quoteSection = "quote-section"
    case specialPropertyInPropertiesDrawer = "special-property-in-properties-drawer"
    case invalidEffortProperty = "invalid-effort-property"
    case invalidIDProperty = "invalid-id-property"
    // Timestamps.
    case timestampSyntax = "timestamp-syntax"
    case clockSyntax = "clock-syntax"
    case planningInactive = "planning-inactive"
    case mismatchedPlanningRepeaters = "mismatched-planning-repeaters"
    // Footnotes.
    case undefinedFootnoteReference = "undefined-footnote-reference"
    case unreferencedFootnoteDefinition = "unreferenced-footnote-definition"

    /// org-lint has a checker by this name.
    public var isOrgLint: Bool {
        switch self {
        case .invalidFileSearch, .missingAttachmentFolder, .orphanedAttachmentFolder, .duplicateID, .unknownTodoKeyword: false
        default: true
        }
    }

    public var trust: LintTrust {
        switch self {
        case .linkToLocalFile, .invalidFileSearch, .orphanedAttachmentFolder, .incompleteDrawer, .invalidBlock, .misplacedPlanningInfo,
             .misplacedHeading, .indentedDiarySexp, .invalidKeywordSyntax, .orphanedAffiliatedKeywords, .deprecatedExportBlocks,
             .nonExistentSetupfileParameter, .unknownTodoKeyword, .quoteSection, .timestampSyntax, .clockSyntax,
             .mismatchedPlanningRepeaters:
            .low
        default:
            .high
        }
    }
}

/// One problem in a file.
public struct LintFinding: Sendable, Equatable, Hashable, Identifiable {
    /// UTF-16 offset in the file's text.
    public let offset: Int
    /// 1-based.
    public let line: Int
    public let checker: LintChecker
    public let message: String

    public init(offset: Int, line: Int, checker: LintChecker, message: String) {
        self.offset = offset
        self.line = line
        self.checker = checker
        self.message = message
    }

    public var trust: LintTrust { checker.trust }

    public var id: String { "\(offset) \(checker.rawValue) \(message)" }
}

/// What the checkers know of the world outside the file: the file system and the workspace's
/// IDs. The file system's paths are absolute.
public struct LintEnvironment: Sendable {
    public var fileExists: @Sendable (String) -> Bool
    public var isDirectory: @Sendable (String) -> Bool
    /// The names in a folder.
    public var contentsOfDirectory: @Sendable (String) -> [String]
    /// The text of an Org file another file links into.
    public var readFile: @Sendable (String) -> String?
    /// The other files whose entries or file property drawers have this ID. Nil without a
    /// workspace index: IDs then resolve in the file alone, and attachment folders aren't
    /// checked for entries.
    public var idFiles: (@Sendable (String) -> [String])?
    /// `org-attach-id-dir` and `org-attach-use-inheritance`, as `OrgAttach.directory` takes them.
    public var attachIDDir: String
    public var attachInherit: Bool?
    /// `org-crypt-tag-matcher`: entries with this tag and an encrypted body aren't linted inside.
    public var cryptTag: String

    public init(
        fileExists: @escaping @Sendable (String) -> Bool, isDirectory: @escaping @Sendable (String) -> Bool,
        contentsOfDirectory: @escaping @Sendable (String) -> [String], readFile: @escaping @Sendable (String) -> String?,
        idFiles: (@Sendable (String) -> [String])? = nil, attachIDDir: String = "data/", attachInherit: Bool? = nil, cryptTag: String = "crypt"
    ) {
        self.fileExists = fileExists
        self.isDirectory = isDirectory
        self.contentsOfDirectory = contentsOfDirectory
        self.readFile = readFile
        self.idFiles = idFiles
        self.attachIDDir = attachIDDir
        self.attachInherit = attachInherit
        self.cryptTag = cryptTag
    }

    /// The local file system, with no workspace index.
    public static let fileSystem = LintEnvironment(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        isDirectory: { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        },
        contentsOfDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
        readFile: { try? String(contentsOfFile: $0, encoding: .utf8) }
    )
}

/// Lint File: problems in one Org file, as org-lint reports them. Reports only; nothing is
/// changed. The file is the whole input, so a command over many files runs this once per file
/// with one environment.
public enum OrgLint {
    /// The findings in `text`, parsed as `tree`, by offset. `path` is where the file is, for
    /// relative links, setup files and attachments; nil skips those checks.
    public static func lint(_ text: String, tree: OrgTree, path: String?, environment: LintEnvironment = .fileSystem) -> [LintFinding] {
        var linter = Linter(text: text, tree: tree, path: path, environment: environment)
        linter.run()
        return linter.findings.sorted { ($0.offset, $0.checker.order) < ($1.offset, $1.checker.order) }
    }
}

extension LintChecker {
    var order: Int { Self.allCases.firstIndex(of: self)! }
}
