import Foundation
import Testing
@testable import OrgCore

/// Timing checks for backlinks, run with the other gates (`ORGSTAR_GATES=1 swift test -c release
/// --filter GateTests`) rather than in the parallel suite, where other tests' load decides them.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_GATES"] != nil), .serialized)
struct BacklinkGateTests {
    let heading = Backlinks.Target(path: "/notes/a.org", title: "Fix the sink [1/2]", id: "abc-1", customID: "sink")

    /// The patterns are compiled once, not for each link: testing the links takes less time
    /// than compiling them that often would.
    @Test func testsManyLinksWithoutCompilingPatterns() throws {
        let links = (0..<4_000).map { ["id:abc-\($0)", "file:a.org::*Fix the sink", "https://example.org/\($0)", "Fix the sink"][$0 % 4] }
        let clock = ContinuousClock()
        // The fastest of several interleaved rounds, which other work on the machine can't slow.
        var compiling = Duration.seconds(Int64.max)
        var testing = Duration.seconds(Int64.max)
        for _ in 0..<5 {
            compiling = min(compiling, try clock.measure {
                for index in links.indices {
                    _ = try NSRegularExpression(pattern: "(\\\\+)(?=$|[\\[\\]])")
                    if index % 2 == 0 { _ = try Regex("^[a-zA-Z][-a-zA-Z0-9+]*:") }
                }
            })
            var hits = 0
            testing = min(testing, clock.measure {
                for link in links where Backlinks.links(link, from: "/notes/b.org", to: heading, home: "/home") { hits += 1 }
            })
            #expect(hits == 1_000)
        }
        #expect(testing < compiling / 2, "\(testing) against \(compiling)")
    }
}
