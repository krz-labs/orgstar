import Foundation
import Testing
@testable import OrgApp

struct WhatsNewTests {
    private let releases = [ReleaseNotes(version: "2.0.0", items: [.init("star", "Title", "Text")])]

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
    }

    @Test func showsOnceAfterAnUpdate() throws {
        let defaults = try defaults()
        #expect(WhatsNew.pending(version: "1.9.0", firstLaunch: false, defaults: defaults, releases: releases) == nil)
        #expect(WhatsNew.pending(version: "2.0.0", firstLaunch: false, defaults: defaults, releases: releases)?.version == "2.0.0")
        #expect(WhatsNew.pending(version: "2.0.0", firstLaunch: false, defaults: defaults, releases: releases) == nil)
    }

    @Test func showsOnTheFirstVersionThatRecordsWhatWasSeen() throws {
        let defaults = try defaults()
        #expect(WhatsNew.pending(version: "2.0.0", firstLaunch: false, defaults: defaults, releases: releases)?.version == "2.0.0")
    }

    @Test func aNewInstallShowsNothing() throws {
        let defaults = try defaults()
        #expect(WhatsNew.pending(version: "2.0.0", firstLaunch: true, defaults: defaults, releases: releases) == nil)
        #expect(WhatsNew.pending(version: "2.0.0", firstLaunch: false, defaults: defaults, releases: releases) == nil)
    }

    @Test func aVersionWithoutNotesShowsNothing() throws {
        let defaults = try defaults()
        defaults.set("2.0.0", forKey: WhatsNew.seenKey)
        #expect(WhatsNew.pending(version: "2.0.1", firstLaunch: false, defaults: defaults, releases: releases) == nil)
    }

    @Test func itemsHaveDistinctTitles() {
        for release in WhatsNew.releases {
            #expect(Set(release.items.map(\.id)).count == release.items.count)
        }
    }
}
