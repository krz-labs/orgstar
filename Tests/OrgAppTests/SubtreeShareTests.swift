import Foundation
import OrgCore
import Testing
@testable import OrgApp

struct SubtreeShareTests {
    static let text = """
    #+TITLE: Notes
    #+TODO: TODO WAIT | DONE
    #+STARTUP: overview

    * Other
    ** TODO Trip to [[https://example.com][Lisbon]]: plans :travel:
    SCHEDULED: <2026-12-01 Tue>
    :PROPERTIES:
    :DIR: trip
    :END:
    Flights.
    *** Hotel
    :PROPERTIES:
    :DIR: hotel
    :END:
    Booked.
    *** Secret :crypt:
    -----BEGIN PGP MESSAGE-----

    jA0ECQMC
    -----END PGP MESSAGE-----


    ** Next
    """

    @Test func theEntryIsSharedAsTheFileHoldsItPromoted() throws {
        let caret = (Self.text as NSString).range(of: "Flights").location
        let share = try #require(SubtreeShare(text: Self.text, at: caret, path: "/nowhere/notes.org", idDir: "data/", inherit: nil))
        #expect(share.text == """
        #+TODO: TODO WAIT | DONE
        #+STARTUP: overview

        * TODO Trip to [[https://example.com][Lisbon]]: plans :travel:
        SCHEDULED: <2026-12-01 Tue>
        :PROPERTIES:
        :DIR: trip
        :END:
        Flights.
        ** Hotel
        :PROPERTIES:
        :DIR: hotel
        :END:
        Booked.
        ** Secret :crypt:
        -----BEGIN PGP MESSAGE-----

        jA0ECQMC
        -----END PGP MESSAGE-----

        """)
        #expect(share.fileName == "Trip to Lisbon- plans.org")
        #expect(share.attachments.isEmpty)
        #expect(SubtreeShare(text: Self.text, at: 3, path: "/nowhere/notes.org") == nil)
    }

    @Test func attachmentsOfTheEntryAndItsChildrenComeAsFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = FileManager.default
        for dir in ["trip", "hotel", "trip/inside", "elsewhere"] { try files.createDirectory(at: folder.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for file in ["trip/ticket.pdf", "trip/.DS_Store", "hotel/booking.png", "elsewhere/no.txt"] { try Data("x".utf8).write(to: folder.appendingPathComponent(file)) }
        let path = folder.appendingPathComponent("notes.org").path
        let caret = (Self.text as NSString).range(of: "Flights").location
        let share = try #require(SubtreeShare(text: Self.text, at: caret, path: path, idDir: "data/", inherit: nil))
        #expect(share.attachments.map(\.lastPathComponent) == ["ticket.pdf", "booking.png"])
        // Only the child's own folder for the child.
        let child = try #require(SubtreeShare(text: Self.text, at: (Self.text as NSString).range(of: "Booked").location, path: path, idDir: "data/", inherit: nil))
        #expect(child.attachments.map(\.lastPathComponent) == ["booking.png"])

        let file = try share.writeFile()
        defer { try? files.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.lastPathComponent == "Trip to Lisbon- plans.org")
        #expect(try String(contentsOf: file, encoding: .utf8) == share.text)
        #expect(share.files(file: file, withAttachments: false) == [file])
        #expect(share.files(file: file, withAttachments: true).map(\.lastPathComponent) == ["Trip to Lisbon- plans.org", "ticket.pdf", "booking.png"])
    }

    @Test func fileNamesAreSafe() {
        #expect(SubtreeShare.fileName("a/b: c?") == "a-b- c-.org")
        #expect(SubtreeShare.fileName("  ") == "Subtree.org")
        #expect(SubtreeShare.fileName("..hidden") == "hidden.org")
        #expect(SubtreeShare.fileName(String(repeating: "x", count: 100)).count == 84)
    }
}
