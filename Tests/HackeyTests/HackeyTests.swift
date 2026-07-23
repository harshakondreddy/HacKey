import Testing
@testable import Hackey

@Test
func labelsAreUniqueAndCountMatches() async throws {
    let labels = AXElementScanner.makeLabels(count: 300)
    #expect(labels.count == 300)
    #expect(Set(labels).count == 300)
}

@Test
func labelsAreFixedWidthAndPrefixFree() async throws {
    // Every label in a batch must be the same length, otherwise typing a shorter
    // label that is a literal prefix of a longer one commits to the shorter
    // target before the longer one's remaining keystrokes can ever be read,
    // making it permanently unreachable. This is the exact bug reported: once a
    // window had more than 26 targets, dozens of two-character labels sharing a
    // first letter with a single-character label became un-clickable.
    for count in [1, 2, 26, 27, 50, 160, 300, 676] {
        let labels = AXElementScanner.makeLabels(count: count)
        let lengths = Set(labels.map { $0.count })
        #expect(lengths.count <= 1, "all labels for count=\(count) must share one fixed width")
        for candidate in labels {
            let sharesPrefix = labels.contains { other in
                other != candidate && other.hasPrefix(candidate)
            }
            #expect(!sharesPrefix, "label \(candidate) must not be a prefix of another label (count=\(count))")
        }
    }
}

@Test
func numericLabelsCycleAsExpected() async throws {
    let labels = AXElementScanner.makeNumericLabels(count: 12)
    #expect(labels == ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "1"])
}

@Test
func numericLabelsAreUniqueUpToTen() async throws {
    // Scroll-mode selection only ever reads a single digit keystroke (0-9), so any
    // caller must cap requested counts at 10 - beyond that, makeNumericLabels'
    // `% 10` wraparound (verified above) produces duplicate, keystroke-ambiguous
    // labels. This test guards the invariant that AXElementScanner.scanScrollAreas
    // relies on: up to 10 labels must always be unique.
    for count in 0...10 {
        let labels = AXElementScanner.makeNumericLabels(count: count)
        #expect(Set(labels).count == count)
    }
}
