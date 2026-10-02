import Foundation
import Testing
@testable import BenchBar

@Suite("CLI locator")
struct CLILocatorTests {
    @Test func searchOrder() {
        let locator = CLILocator(home: URL(fileURLWithPath: "/Users/you"), isExecutable: { _ in false }, resolve: { $0 })
        #expect(locator.candidates(userPath: "~/src/benchbar") == [
            (("~/src/benchbar") as NSString).expandingTildeInPath,
            "/opt/homebrew/bin/benchbar",
            "/Users/you/.local/bin/benchbar",
            "/usr/local/bin/benchbar",
            "/Users/you/.local/bin/frappe-mac",
        ])
        #expect(locator.candidates(userPath: nil).first == "/opt/homebrew/bin/benchbar")
    }

    @Test func intelHomebrewComesBeforeLocalBinOnlyWhenItIsTheFormula() throws {
        let brew = CLILocator(home: URL(fileURLWithPath: "/Users/you"), isExecutable: { _ in false }, resolve: { path in
            path == "/usr/local/bin/benchbar" ? "/usr/local/Cellar/benchbar/0.7.0/bin/benchbar" : path
        })
        #expect(brew.candidates(userPath: nil) == [
            "/opt/homebrew/bin/benchbar",
            "/usr/local/bin/benchbar",
            "/Users/you/.local/bin/benchbar",
            "/Users/you/.local/bin/frappe-mac",
        ])
        // an old copy there that is not Homebrew's must not shadow the one line installer's link
        let stale = CLILocator(home: URL(fileURLWithPath: "/Users/you"), isExecutable: { $0 != "/opt/homebrew/bin/benchbar" },
                               resolve: { $0 == "/usr/local/bin/benchbar" ? "/Users/you/old/frappe-mac/benchbar" : $0 })
        #expect(try stale.locate(userPath: nil).path == "/Users/you/.local/bin/benchbar")
    }

    @Test func prefersHomebrewOverLocalBin() throws {
        let installed: Set = ["/opt/homebrew/bin/benchbar", "/Users/you/.local/bin/benchbar"]
        let locator = CLILocator(home: URL(fileURLWithPath: "/Users/you"), isExecutable: { installed.contains($0) },
                                 exists: { installed.contains($0) }, resolve: { $0 })
        #expect(try locator.locate(userPath: nil).path == "/opt/homebrew/bin/benchbar")
        // a path saved in Settings (0.6.x saved ~/.local/bin) still wins
        #expect(try locator.locate(userPath: "/Users/you/.local/bin/benchbar").path == "/Users/you/.local/bin/benchbar")
    }

    @Test func findsTheLocalBinLink() throws {
        let home = try TempDir()
        try home.write(".local/bin/benchbar", "#!/bin/sh\n", executable: true)
        let root = home.url.path
        let locator = CLILocator(home: home.url, isExecutable: { path in
            path.hasPrefix(root) && FileManager.default.isExecutableFile(atPath: path)
        }, resolve: { $0 })
        #expect(try locator.locate(userPath: nil).path == home.url.appendingPathComponent(".local/bin/benchbar").path)
    }

    @Test func aCellarPathInSettingsMeansTheOptLink() throws {
        let opt = "/opt/homebrew/opt/benchbar/bin/benchbar"
        let locator = CLILocator(home: URL(fileURLWithPath: "/Users/you"), isExecutable: { $0 == opt }, exists: { $0 == opt }, resolve: { $0 })
        #expect(locator.saved("/opt/homebrew/Cellar/benchbar/0.7.0/bin/benchbar") == opt)
        #expect(locator.saved("/usr/local/Cellar/benchbar/0.7.0/libexec/benchbar") == "/usr/local/opt/benchbar/bin/benchbar")
        #expect(try locator.locate(userPath: "/opt/homebrew/Cellar/benchbar/0.6.9/libexec/benchbar").path == opt,
                "the old version's folder is gone after brew cleanup; the opt link is not")
        #expect(Homebrew.stablePath("/Users/you/.local/bin/benchbar") == "/Users/you/.local/bin/benchbar")
        #expect(Homebrew.stablePath("/Cellar/benchbar/1/benchbar") == "/Cellar/benchbar/1/benchbar", "no prefix, not Homebrew's")
    }

    @Test func aVanishedSettingFallsBackToAutomatic() throws {
        let locator = CLILocator(home: URL(fileURLWithPath: "/Users/you"), isExecutable: { $0 == "/Users/you/.local/bin/benchbar" },
                                 exists: { $0 == "/Users/you/.local/bin/benchbar" }, resolve: { $0 })
        #expect(try locator.locate(userPath: "/Users/you/dev/moved-away/benchbar").path == "/Users/you/.local/bin/benchbar")
        // nothing anywhere: the error lists the saved path too
        let none = CLILocator(home: URL(fileURLWithPath: "/Users/you"), isExecutable: { _ in false }, exists: { _ in false }, resolve: { $0 })
        #expect {
            try none.locate(userPath: "/Users/you/dev/moved-away/benchbar")
        } throws: { error in
            guard case CLIError.notFound(let searched) = error else { return false }
            return searched.first == "/Users/you/dev/moved-away/benchbar" && searched.count == 5
        }
    }

    @Test func homebrewPathsAreRecognized() {
        #expect(Homebrew.prefix(ofCLI: "/opt/homebrew/Cellar/benchbar/0.7.0/libexec/benchbar") == "/opt/homebrew")
        #expect(Homebrew.prefix(ofCLI: "/usr/local/opt/benchbar/bin/benchbar") == "/usr/local")
        #expect(Homebrew.prefix(ofCLI: "/Users/you/.local/share/benchbar/benchbar") == nil)
        #expect(Homebrew.prefix(ofCLI: "/opt/benchbar/bin/benchbar") == nil, "a hand made /opt folder is not Homebrew's")
        #expect(Homebrew.prefix(ofCLI: "/Users/you/opt/benchbar/benchbar") == nil, "a checkout in ~/opt/benchbar is not Homebrew's")
    }

    @Test func fallsBackToTheFrappeMacAlias() throws {
        let home = try TempDir()
        try home.write(".local/bin/frappe-mac", "#!/bin/sh\n", executable: true)
        let root = home.url.path
        let locator = CLILocator(home: home.url, isExecutable: { path in
            path.hasPrefix(root) && FileManager.default.isExecutableFile(atPath: path)
        }, resolve: { $0 })
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
        let locator = CLILocator(home: URL(fileURLWithPath: "/nonexistent"), isExecutable: { _ in false }, resolve: { $0 })
        #expect {
            try locator.locate(userPath: nil)
        } throws: { error in
            guard case CLIError.notFound(let searched) = error else { return false }
            return searched.count == 4
        }
    }
}
