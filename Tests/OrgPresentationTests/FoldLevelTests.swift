import Foundation
import Testing
import OrgCore
@testable import OrgPresentation

/// The fold states behind Doom's `zO`, `zR`, `zM`, `zr` and `zm`.
struct FoldLevelTests {
    static let text = "* A\nbody\n** B\ntext\n*** C\ndeep\n* D\n** E\n"
    let tree = OrgParser.parse(FoldLevelTests.text)

    private func at(_ heading: String) -> Int {
        (Self.text as NSString).range(of: heading).location
    }

    @Test func closesAndOpensEverything() {
        let wrappers: Set<Int> = [4]
        let closed = Presentation.hideSublevels(1, in: tree, FoldState(wrapperFolds: wrappers))
        #expect(closed == FoldState(folds: [at("* A"), at("* D")], wrapperFolds: wrappers))
        #expect(Presentation.showAllHeadings(closed) == FoldState(wrapperFolds: wrappers))
    }

    @Test func stepsThroughLevels() {
        var state = Presentation.hideSublevels(1, in: tree, FoldState())
        #expect(Presentation.foldLevel(in: tree, state) == 1)
        state = Presentation.hideSublevels(Presentation.foldLevel(in: tree, state) + 1, in: tree, state)
        #expect(state == FoldState(folds: [at("** B"), at("** E")], bodyFolds: [at("* A"), at("* D")]))
        #expect(Presentation.foldLevel(in: tree, state) == 2)
        state = Presentation.hideSublevels(Presentation.foldLevel(in: tree, state) + 1, in: tree, state)
        #expect(Presentation.foldLevel(in: tree, state) == 3)
        state = Presentation.hideSublevels(Presentation.foldLevel(in: tree, state) - 1, in: tree, state)
        #expect(state.folds == [at("** B"), at("** E")])
        // A folded heading inside a folded subtree doesn't show, so it doesn't count.
        #expect(Presentation.foldLevel(in: tree, FoldState(folds: [at("* A"), at("*** C")])) == 1)
        #expect(Presentation.foldLevel(in: tree, FoldState()) == 1)
    }

    @Test func opensASubtree() {
        let state = FoldState(folds: [at("* A"), at("*** C"), at("* D")], bodyFolds: [at("** B"), at("** E")])
        #expect(Presentation.showSubtree(at("* A"), in: tree, state) == FoldState(folds: [at("* D")], bodyFolds: [at("** E")]))
        #expect(Presentation.showSubtree(at("** B"), in: tree, state) == FoldState(folds: [at("* A"), at("* D")], bodyFolds: [at("** E")]))
    }
}
