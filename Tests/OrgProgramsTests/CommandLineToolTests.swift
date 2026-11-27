import Foundation
import Testing
import OrgPrograms

struct CommandLineToolTests {
    @Test func linksTheHelperAndReplacesALink() throws {
        let folder = try Folder()
        let app = folder.url.appendingPathComponent("orgstar.app")
        let helper = try folder.write("orgstar.app/Contents/Helpers/orgstar", "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        #expect(CommandLineTool.helper(in: app) == helper)
        let bin = folder.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("orgstar").path, withDestinationPath: "/old/orgstar")
        let link = try CommandLineTool.install(helper, in: bin)
        #expect(link == bin.appendingPathComponent("orgstar"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == helper.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path) == ["orgstar"])
    }

    @Test func leavesOtherFilesAndReportsWhy() throws {
        let folder = try Folder()
        let helper = try folder.write("orgstar.app/Contents/Helpers/orgstar", "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let file = try folder.write("bin/orgstar", "mine")
        #expect(throws: CommandLineTool.Failure.occupied(path: file.path)) { try CommandLineTool.install(helper, in: file.deletingLastPathComponent()) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine")
        #expect(throws: CommandLineTool.Failure.missing) { try CommandLineTool.install(folder.url.appendingPathComponent("none"), in: folder.url) }
        let locked = folder.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect {
            try CommandLineTool.install(helper, in: locked)
        } throws: { error in
            guard case .unwritable(let path, _) = error as? CommandLineTool.Failure else { return false }
            return path == locked.path
        }
    }
}
