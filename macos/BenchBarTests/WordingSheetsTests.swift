import Foundation
import Testing
@testable import BenchBar

/// The counts of the sheets, tidy and profile surfaces (Wording+Sheets.swift), and the
/// catalogue keys behind them.
@Suite("Wording, sheets")
struct WordingSheetsTests {
    @Test func countsUseTheCataloguePluralForms() {
        #expect(Wording.exportedApps(1) == "Exported 1 app")
        #expect(Wording.exportedApps(3) == "Exported 3 apps")
        #expect(Wording.commitsBehind(1) == "1 commit behind")
        #expect(Wording.commitsBehind(4) == "4 commits behind")
        #expect(Wording.repositoriesNotReachable(1) == "1 repository is not reachable")
        #expect(Wording.repositoriesNotReachable(2) == "2 repositories are not reachable")
        #expect(Wording.markScratch("v16-bench", days: 1) == "Mark v16-bench scratch for 1 day")
        #expect(Wording.markScratch("v16-bench", days: 3) == "Mark v16-bench scratch for 3 days")
        #expect(Wording.apps(3) == "3 apps")
        #expect(Wording.apps(1) == "1 app")
    }

    /// The hand built text said "1 line ... name"; one line names.
    @Test func oneStaleHostsLineTakesTheSingularVerb() {
        #expect(Wording.staleHostsLines(1) == "1 line in /etc/hosts names no site of any bench:")
        #expect(Wording.staleHostsLines(3) == "3 lines in /etc/hosts name no site of any bench:")
    }

    /// Two numbers in one sentence: the noun and the verb follow the first, the second stays a number.
    @Test func orphanDatabasesAgreeWithTheirCount() {
        #expect(Wording.orphanDatabases(1, checked: 3) == "1 database of 3 has no site in any bench benchbar knows.")
        #expect(Wording.orphanDatabases(2, checked: 3) == "2 databases of 3 have no site in any bench benchbar knows.")
        #expect(Wording.orphanDatabases(2, checked: 1) == "2 databases of 1 have no site in any bench benchbar knows.")
    }
}
