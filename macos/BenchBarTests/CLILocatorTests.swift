import Foundation
import Testing
@testable import BenchBar

@Suite("CLI locator")
struct CLILocatorTests {
    @Test func searchOrder() {
        let locator = CLILocator(home: URL(fileURLWithPath: "/Users/you"), isExecutable: { _ in false })
        #expect(locator.candidates(userPath: "~/src/benchbar") == [
            (("~/src/benchbar") as NSString).expandingTildeInPath,
            "/Users/you/.local/bin/benchbar",
            "/opt/homebrew/bin/benchbar",
            "/usr/local/bin/benchbar",
            "/Users/you/.local/bin/frappe-mac",
        ])
        #expect(locator.candidates(userPath: nil).first == "/Users/you/.local/bin/benchbar")
    }

    @Test func prefersLocalBinOverHomebrew() throws {
        let home = try TempDir()
        try home.write(".local/bin/benchbar", "#!/bin/sh\n", executable: true)
        let locator = CLILocator(home: home.url)
        #expect(try locator.locate(userPath: nil).path == home.url.appendingPathComponent(".local/bin/benchbar").path)
    }

    @Test func fallsBackToTheFrappeMacAlias() throws {
        let home = try TempDir()
        try home.write(".local/bin/frappe-mac", "#!/bin/sh\n", executable: true)
        let root = home.url.path
        let locator = CLILocator(home: home.url, isExecutable: { path in
            path.hasPrefix(root) && FileManager.default.isExecutableFile(atPath: path)
        })
        #expect(try locator.locate(userPath: nil).lastPathComponent == "frappe-mac")
    }

    @Test func aBrokenSettingIsReportedNotSkipped() throws {
        let home = try TempDir()
        try home.write(".local/bin/benchbar", "#!/bin/sh\n", executable: true)
        let notExecutable = try home.write("plain.txt", "hello")
        let locator = CLILocator(home: home.url)
        #expect(throws: CLIError.notExecutable(path: notExecutable.path)) {
            try locator.locate(userPath: notExecutable.path)
        }
    }

    @Test func nothingFoundListsWhereItLooked() {
        let locator = CLILocator(home: URL(fileURLWithPath: "/nonexistent"), isExecutable: { _ in false })
        #expect {
            try locator.locate(userPath: nil)
        } throws: { error in
            guard case CLIError.notFound(let searched) = error else { return false }
            return searched.count == 4
        }
    }
}
