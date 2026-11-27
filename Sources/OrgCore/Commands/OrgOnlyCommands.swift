/// Commands that read or write org syntax in the open file, refused in Markdown and other
/// text files so none of them writes org into one.
public enum OrgOnlyCommands {
    /// Visibility commands, which fold Markdown headings as they fold org ones.
    public static func folds(_ id: String) -> Bool {
        id == "org.cycle" || id == "org.cycle-global" || id.hasPrefix("org.fold.")
    }

    /// Whether `id` is refused in a file that isn't org; `markdown` lets the fold commands run,
    /// and a `path` with a Denote file type lets Denote's link and rename commands run.
    public static func refuses(_ id: String, markdown: Bool, path: String? = nil) -> Bool {
        if markdown, folds(id) { return false }
        if denoteCommands.contains(id), let path, Denote.FileType(path: path) != nil { return false }
        if id.hasPrefix("org.") || id.hasPrefix("app.attach.") { return true }
        if id.hasPrefix("app.export.") { return !id.hasPrefix("app.export.icalendar-") }
        return appCommands.contains(id)
    }

    /// Commands that follow, insert or rename as Denote does in its Markdown and text notes:
    /// Open Link on a `denote:` link, Insert Node Link, Rename Note and Rename Note from Front
    /// Matter.
    static let denoteCommands: Set<String> = ["org.link.open", "app.node.insert", "app.node.rename", "app.node.rename-from-front-matter"]

    /// App commands that act on the open file's entries, tables, links or Denote front matter.
    static let appCommands: Set<String> = [
        "app.refile", "app.refile.copy", "app.archive", "app.clock.in", "app.clock.default", "app.copy-rich-text",
        "app.export-dialog", "app.export-subtree-dialog", "app.export-subtree", "app.export-body-only", "app.share-subtree",
        "app.table-import", "app.table-export", "app.table-export.tsv", "app.plot",
        "app.crypt.encrypt-entry", "app.crypt.encrypt-entries", "app.crypt.open-entry", "app.crypt.decrypt-entry",
        "app.node.insert", "app.node.rename", "app.node.rename-from-front-matter",
        "app.node.sequence-convert", "app.node.sequence-link", "app.node.sequence-rename-as-parent", "app.node.sequence-reparent",
        "app.node.sequence-reparent-recursive", "app.node.sequence-new-child-of-current", "app.node.sequence-new-sibling-of-current",
        "app.publish.current-file", "app.present",
    ]
}
