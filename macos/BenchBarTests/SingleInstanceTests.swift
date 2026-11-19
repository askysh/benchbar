import Foundation
import Testing
@testable import BenchBar

@Suite("Two copies of the app")
struct SingleInstanceTests {
    @Test func anotherLiveProcessMeansHandOver() {
        let others = [SingleInstance.Other(pid: 100, isTerminated: false), SingleInstance.Other(pid: 200, isTerminated: false)]
        #expect(SingleInstance.copyToHandOverTo(others: others, mine: 200)?.pid == 100)
    }

    @Test func aloneOrWithATerminatedCopyGoesOn() {
        #expect(SingleInstance.copyToHandOverTo(others: [], mine: 200) == nil)
        #expect(SingleInstance.copyToHandOverTo(others: [.init(pid: 200, isTerminated: false)], mine: 200) == nil, "myself is not another copy")
        #expect(SingleInstance.copyToHandOverTo(others: [.init(pid: 100, isTerminated: true)], mine: 200) == nil)
    }

    @MainActor
    @Test func theTestHostAndTheOverrideNeverHandOver() {
        #expect(!SingleInstance.yieldToRunningCopy(environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(!SingleInstance.yieldToRunningCopy(environment: ["BENCHBAR_ALLOW_SECOND_COPY": "1"]))
    }
}

@Suite("App CLI link order")
struct AppCLILinkOrderTests {
    let system = "/Applications/BenchBar.app/Contents/Resources/cli/benchbar"
    let user = "/Users/you/Applications/BenchBar.app/Contents/Resources/cli/benchbar"
    let userOther = "/Users/you/Applications/Old/BenchBar.app/Contents/Resources/cli/benchbar"

    func may(current: String?, with target: String, this: String = "0.9.0", versions: [String: String] = [:], exists: Bool = true) -> Bool {
        AppCLILink.mayReplace(current: current, with: target, thisVersion: this, exists: { _ in exists }, versionOf: { versions[$0] })
    }

    @Test func noLinkOrABrokenLinkIsTaken() {
        #expect(may(current: nil, with: user))
        #expect(may(current: system, with: user, exists: false), "the copy it led to is gone")
    }

    /// MAC-11: an old copy in ~/Applications that was launched again must not take the link
    /// from the one in /Applications, whatever the versions say.
    @Test func theCopyInApplicationsKeepsTheLink() {
        #expect(!may(current: system, with: user))
        #expect(!may(current: system, with: user, this: "9.9.9", versions: [system: "0.1.0"]))
    }

    @Test func theCopyInApplicationsTakesItBack() {
        #expect(may(current: user, with: system))
        #expect(may(current: user, with: system, this: "0.1.0", versions: [user: "9.9.9"]))
    }

    @Test func onTheSameLevelTheLinkNeverGoesToAnOlderCopy() {
        #expect(!may(current: user, with: userOther, this: "0.8.3", versions: [user: "0.9.0"]))
        #expect(may(current: user, with: userOther, this: "0.9.0", versions: [user: "0.9.0"]), "the same version: the launching copy")
        #expect(may(current: user, with: userOther, this: "0.10.0", versions: [user: "0.9.0"]), "0.10 is newer than 0.9")
        #expect(may(current: user, with: userOther, this: "0.8.3", versions: [:]), "a version nobody can read does not block")
    }

    @Test func theVersionOfACLIIsReadFromItsApp() {
        #expect(AppCLILink.appVersion(ofCLI: "/nonexistent/BenchBar.app/Contents/Resources/cli/benchbar") == nil)
        #expect(AppCLILink.appVersion(ofCLI: "/usr/local/bin/benchbar") == nil)
    }
}
