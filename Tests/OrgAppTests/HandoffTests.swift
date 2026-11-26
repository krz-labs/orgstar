import Foundation
import Testing
@testable import OrgApp

struct HandoffTests {
    static let text = """
    #+TITLE: Notes
    * Work
    ** Project
    :PROPERTIES:
    :ID: project-1
    :END:
    first line
    second line
    ** Other
    * Home

    """

    @Test func placeRoundTripsThroughUserInfo() throws {
        let path = "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/org/notes/todo.org"
        let caret = (Self.text as NSString).range(of: "second").location + 3
        let place = try #require(HandoffPlace.make(path: path, text: Self.text, caret: caret, roots: ["/Users/a/Library/Mobile Documents/com~apple~CloudDocs/org"]))
        #expect(place.folder == "org")
        #expect(place.file == "notes/todo.org")
        #expect(place.cloudPath == "com~apple~CloudDocs/org/notes/todo.org")
        #expect(place.outline == ["Work", "Project"])
        #expect(place.id == "project-1")
        #expect(place.line == 8)
        #expect(place.headingLine == 3)
        // Through a property list, as Handoff sends it.
        let data = try PropertyListSerialization.data(fromPropertyList: place.userInfo, format: .binary, options: 0)
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [AnyHashable: Any])
        #expect(HandoffPlace(userInfo: info) == place)
        #expect(!place.userInfo.values.contains { ($0 as? String)?.contains("second line") == true })
    }

    @Test func nothingIsAdvertisedOutsideTheFoldersOrForEncryptedFiles() {
        #expect(HandoffPlace.make(path: "/elsewhere/a.org", text: "", caret: 0, roots: ["/org"]) == nil)
        #expect(HandoffPlace.make(path: "/org/secret.org.gpg", text: "", caret: 0, roots: ["/org"]) == nil)
        #expect(HandoffPlace.make(path: "/org/a.org", text: "", caret: 0, roots: ["/org"])?.file == "a.org")
        // The innermost of nested roots.
        #expect(HandoffPlace.make(path: "/org/work/a.org", text: "", caret: 0, roots: ["/org", "/org/work"])?.folder == "work")
    }

    @Test func userInfoMustNameAFileInsideTheFolder() {
        #expect(HandoffPlace(userInfo: ["folder": "org", "file": "../etc/passwd"]) == nil)
        #expect(HandoffPlace(userInfo: ["folder": "org", "file": "/etc/passwd"]) == nil)
        #expect(HandoffPlace(userInfo: ["folder": "org"]) == nil)
        #expect(HandoffPlace(userInfo: nil) == nil)
        #expect(HandoffPlace(userInfo: ["folder": "org", "file": "a.org"])?.line == 1)
    }

    @Test func iCloudFoldersMatchByTheirPathInICloud() {
        let place = HandoffPlace(folder: "org", cloudPath: "com~apple~CloudDocs/org/notes/todo.org", file: "notes/todo.org",
                                 outline: [], id: nil, line: 1, headingLine: 0)
        let phone = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/org"
        #expect(place.resolve(roots: [phone], exists: { _ in true }) == .file(phone + "/notes/todo.org"))
        // A root higher up in iCloud Drive holds the file too.
        let drive = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(place.resolve(roots: [drive], exists: { _ in true }) == .file(drive + "/org/notes/todo.org"))
        // Another iCloud folder named org is not this one, so the name decides only without a match.
        let other = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/archive/org"
        #expect(place.resolve(roots: [other, phone], exists: { _ in true }) == .file(phone + "/notes/todo.org"))
    }

    @Test func otherFoldersMatchByName() {
        let place = HandoffPlace(folder: "notes", cloudPath: nil, file: "a/b.org", outline: [], id: nil, line: 1, headingLine: 0)
        let root = "/private/var/mobile/Containers/Shared/AppGroup/1234/File Provider Storage/notes"
        #expect(place.resolve(roots: ["/x/org", root], exists: { _ in true }) == .file(root + "/a/b.org"))
        #expect(place.resolve(roots: ["/x/org"], exists: { _ in true }) == .noFolder)
        #expect(place.resolve(roots: [root], exists: { _ in false }) == .noFile)
        // Two folders of that name: the one with the file.
        #expect(place.resolve(roots: ["/y/notes", root], exists: { $0.hasPrefix(root) }) == .file(root + "/a/b.org"))
        // An iCloud file on a device without that iCloud folder still matches by name.
        let cloud = HandoffPlace(folder: "notes", cloudPath: "com~apple~CloudDocs/notes/a/b.org", file: "a/b.org", outline: [], id: nil, line: 1, headingLine: 0)
        #expect(cloud.resolve(roots: [root], exists: { _ in true }) == .file(root + "/a/b.org"))
    }

    @Test func caretGoesToTheHeadingByIDThenOutlineThenLine() {
        let place = HandoffPlace(folder: "org", cloudPath: nil, file: "a.org", outline: ["Work", "Project"], id: "project-1", line: 8, headingLine: 3)
        let ns = Self.text as NSString
        let second = ns.range(of: "second line").location
        #expect(place.offset(in: Self.text) == second)
        // Lines added above the heading on this device: the heading is found by ID.
        let moved = "* New\nnew text\n" + Self.text
        #expect(place.offset(in: moved) == (moved as NSString).range(of: "second line").location)
        // Without the ID, by the outline path.
        var byOutline = place
        byOutline.id = "gone"
        #expect(byOutline.offset(in: moved) == (moved as NSString).range(of: "second line").location)
        // Neither: the same line.
        let unrelated = HandoffPlace(folder: "org", cloudPath: nil, file: "a.org", outline: ["Nope"], id: nil, line: 3, headingLine: 2)
        #expect(unrelated.offset(in: Self.text) == ns.range(of: "** Project").location)
        // A line past the heading's text stays in it.
        let long = HandoffPlace(folder: "org", cloudPath: nil, file: "a.org", outline: ["Work", "Project"], id: nil, line: 40, headingLine: 3)
        #expect(long.offset(in: Self.text) == ns.range(of: "** Other").location - 1)
    }
}
