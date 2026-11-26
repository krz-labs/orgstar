import Foundation
import Testing
@testable import OrgApp

/// The iOS editor's Commands list, read from its source as CommandTitleTests does: the target
/// isn't built by `swift test`.
struct EditorCommandListTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func viewCommands() throws -> [(id: String, title: String)] {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OrgstarMobile/EditorScreen.swift"), encoding: .utf8)
        return source.matches(of: /\("((?:app|org|edit|editor|view)\.[^"]+)", "([^"\\]+)"\)/).map { (String($0.1), String($0.2)) }
    }

    /// #236: Export is in Commands, under Export, since the iPhone toolbar has no room for it.
    @Test func exportIsInTheEditorsCommands() throws {
        let commands = try Self.viewCommands()
        #expect(commands.contains { $0 == ("app.export-dialog", "Export…") })
        #expect(commands.contains { $0 == ("app.export-subtree-dialog", "Export Subtree…") })
        let export = try #require(CommandGroups.commandList.firstIndex { $0.prefixes.contains("app.export") })
        #expect(CommandGroups.group(of: "app.export-dialog", in: CommandGroups.commandList) == export)
        #expect(CommandGroups.group(of: "app.export-subtree-dialog", in: CommandGroups.commandList) == export)
    }
}
