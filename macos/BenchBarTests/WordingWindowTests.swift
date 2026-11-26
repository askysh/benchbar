import Foundation
import Testing
@testable import BenchBar

/// The counts and the relative age of the main window (Wording+Window.swift), and the
/// catalogue keys behind them.
@Suite("Wording, main window")
struct WordingWindowTests {
    @Test func countsUseTheCataloguePluralForms() {
        #expect(Wording.differences(1) == "1 difference")
        #expect(Wording.differences(0) == "0 differences")
        #expect(Wording.differences(4) == "4 differences")
        #expect(Wording.scanWarnings(1) == "1 scan warning")
        #expect(Wording.scanWarnings(2) == "2 scan warnings")
        #expect(Wording.itsSteps(1) == "its 1 step")
        #expect(Wording.itsSteps(3) == "its 3 steps")
        #expect(Wording.newCommits(1, on: "main") == "1 new commit on main:")
        #expect(Wording.newCommits(5, on: "the branch") == "5 new commits on the branch:")
    }

    @Test func aMomentAfterNowReadsAsNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        #expect(Wording.relativeAge(of: now.addingTimeInterval(-7200), now: now, locale: english) == "2 hours ago")
        #expect(Wording.relativeAge(of: now.addingTimeInterval(300), now: now, locale: english)
            == Wording.relativeAge(of: now, now: now, locale: english))
    }
}
