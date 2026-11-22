import Foundation
import Testing
import OrgPresentation
@testable import OrgEditorAppKit

/// SplitMix64, so failures reproduce from the seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `ORGSTAR_SEED` when set, else `fallback`, so random tests repeat unless asked to vary.
func testSeed(_ fallback: UInt64) -> UInt64 {
    ProcessInfo.processInfo.environment["ORGSTAR_SEED"].flatMap { UInt64($0) } ?? fallback
}

struct LineIndexTests {
    func naive(_ text: String) -> [Int] {
        var starts = [0]
        for (i, u) in text.utf16.enumerated() where u == 10 { starts.append(i + 1) }
        return starts
    }

    @Test func followsRandomEdits() {
        let seed = testSeed(20261122)
        var generator = SeededGenerator(state: seed)
        let pieces = ["a", "bc\n", "\n", "\n\n", "xyz", "é\n", "😀", ""]
        var text = "first\nsecond\n\nthird"
        let index = LineIndex(text as NSString)
        for _ in 0..<2000 {
            let ns = text as NSString
            let start = Int.random(in: 0...ns.length, using: &generator)
            let end = min(ns.length, start + Int.random(in: 0...6, using: &generator))
            let replacement = pieces.randomElement(using: &generator)!
            text = ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: replacement)
            index.replace(start..<end, newLength: (replacement as NSString).length, in: text as NSString)
            #expect(index.starts == naive(text), "seed \(seed)")
            if index.starts != naive(text) { return }
        }
        #expect(index.line(of: 0) == 1)
        #expect(index.line(of: (text as NSString).length) == naive(text).count)
    }
}

@MainActor
struct ShadedBlockTests {
    /// Bands after edits match a full search once typing settles.
    @Test func incrementalMatchesFull() {
        let seed = testSeed(20261122)
        var generator = SeededGenerator(state: seed)
        let pieces = ["x", "word ", "\n", "#+begin_src sh\n", "#+end_src\n", ": fixed\n", "* H\n", "#+begin_quote\n", "#+end_quote\n", ""]
        let h = Harness("* A\n#+begin_src sh\nls\n#+end_src\ntext\n: one\n* B\nbody\n")
        for _ in 0..<400 {
            let length = h.editor.document.text.utf16.count
            let start = Int.random(in: 0...length, using: &generator)
            let end = min(length, start + Int.random(in: 0...5, using: &generator))
            let piece = pieces.randomElement(using: &generator)!
            h.textView.insertText(piece, replacementRange: NSRange(location: start, length: end - start))
            h.editor.settleBlocks()
            let full = Presentation.shadedBlocks(h.editor.document.tree)
            #expect(h.editor.shaded.all == full, "\(h.editor.document.text) seed \(seed)")
            if h.editor.shaded.all != full { return }
        }
    }
}
