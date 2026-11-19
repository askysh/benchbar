import Foundation
import Testing
@testable import BenchBar

@Suite("Notifications")
struct NotifierTests {
    func content(_ alert: BenchAlert) -> AlertContent {
        .make(alert, benchPath: "/Users/me/frappe-bench", name: "frappe-bench", url: "http://macdev:8000")
    }

    @Test func crashNamesTheExitCode() {
        let c = content(.crashed(exitCode: 3))
        #expect(c.title == "frappe-bench crashed")
        #expect(c.body == "honcho exited with code 3. launchd is restarting it.")
        #expect(content(.crashed(exitCode: nil)).body.contains("stopped unexpectedly"))
    }

    @Test func crashGuardSaysRestartsArePaused() {
        let c = content(.crashGuardTripped)
        #expect(c.title == "frappe-bench keeps crashing")
        #expect(c.body.contains("automatic restarts are paused"))
    }

    @Test func recoveryGivesTheURL() {
        let c = content(.recovered)
        #expect(c.title == "frappe-bench is running again")
        #expect(c.body == "http://macdev:8000 is back.")
    }

    @Test func oneIdentifierPerBenchAndKind() {
        #expect(content(.crashed(exitCode: 1)).identifier == content(.crashed(exitCode: 2)).identifier)
        #expect(content(.crashed(exitCode: 1)).identifier != content(.recovered).identifier)
        #expect(content(.recovered).thread == "/Users/me/frappe-bench")
        let other = AlertContent.make(.recovered, benchPath: "/b/other", name: "other", url: "")
        #expect(other.identifier != content(.recovered).identifier)
    }
}

/// MAC-12: a notice is sent only with the switch on and the permission given,
/// the permission question comes once and not at launch, and a refused or
/// failed send is reported.
@Suite("Notification delivery")
struct NotifierDeliveryTests {
    final class FakeCenter: NotificationCentering, @unchecked Sendable {
        private let lock = NSLock()
        private var state: Notifier.Permission
        private let answer: Notifier.Permission
        private var _asked = 0
        private var _sent: [OutgoingNotice] = []
        var failure: Error?
        /// While set, the question stays open until `answer()`, as the system's does.
        var holdQuestion = false
        private var gate: CheckedContinuation<Void, Never>?

        init(_ state: Notifier.Permission, answers: Notifier.Permission = .allowed) {
            self.state = state
            self.answer = answers
        }

        var asked: Int { lock.withLock { _asked } }
        var sent: [OutgoingNotice] { lock.withLock { _sent } }

        func permission() async -> Notifier.Permission { lock.withLock { state } }
        func requestPermission() async {
            lock.withLock { _asked += 1 }
            if holdQuestion { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
            lock.withLock { state = answer }
        }

        var questionIsOpen: Bool { lock.withLock { gate != nil } }

        func answerTheQuestion() {
            let open = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { gate = nil }
                return gate
            }
            open?.resume()
        }
        func add(_ notice: OutgoingNotice) async throws {
            if let failure { throw failure }
            lock.withLock { _sent.append(notice) }
        }
    }

    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    func notifier(_ center: FakeCenter, enabled: Bool = true) throws -> (Notifier, AppSettings) {
        let defaults = try #require(UserDefaults(suiteName: "NotifierDeliveryTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, findEditors: { [] })
        settings.notificationsEnabled = enabled
        return (Notifier(settings: settings, center: center), settings)
    }

    let notice = OutgoingNotice(identifier: "benchbar.crashed./b", title: "b crashed", body: "x", thread: "/b", bench: "/b", sound: true)

    @Test func launchReadsThePermissionButNeverAsks() async throws {
        let center = FakeCenter(.notAsked)
        let (notifier, settings) = try notifier(center)
        await notifier.start(registerDelegate: false).value
        #expect(notifier.permission == .notAsked)
        #expect(center.asked == 0)
        #expect(!settings.askedForNotifications)
    }

    @Test func theFirstNoticeAsksOnceThenSends() async throws {
        let center = FakeCenter(.notAsked)
        let (notifier, settings) = try notifier(center)
        #expect(await notifier.deliver(notice) == .sent)
        #expect(center.asked == 1)
        #expect(settings.askedForNotifications)
        #expect(center.sent == [notice])
        #expect(await notifier.deliver(notice) == .sent)
        #expect(center.asked == 1, "asked once")
    }

    /// Two notices at the first prompt: the second waits for the answer, it is not dropped.
    @Test func aSecondNoticeWaitsForTheQuestionInsteadOfBeingDropped() async throws {
        let center = FakeCenter(.notAsked)
        center.holdQuestion = true
        let (notifier, _) = try notifier(center)
        let second = OutgoingNotice(identifier: "benchbar.crashed./c", title: "c crashed", body: "x", thread: "/c", bench: "/c", sound: true)
        async let first = notifier.deliver(notice)
        for _ in 0..<200 where !center.questionIsOpen { try await Task.sleep(for: .milliseconds(10)) }
        #expect(center.questionIsOpen, "the system's question is on screen")
        async let other = notifier.deliver(second)
        try await Task.sleep(for: .milliseconds(150))
        #expect(center.sent.isEmpty, "nothing is sent while the person has not answered")
        center.answerTheQuestion()
        #expect(await first == .sent)
        #expect(await other == .sent)
        #expect(center.asked == 1, "one question")
        #expect(Set(center.sent.map(\.identifier)) == [notice.identifier, second.identifier])
    }

    @Test func aRefusedQuestionSendsNothingAndDoesNotAskAgain() async throws {
        let center = FakeCenter(.notAsked, answers: .denied)
        let (notifier, _) = try notifier(center)
        #expect(await notifier.deliver(notice) == .notAllowed)
        #expect(await notifier.deliver(notice) == .notAllowed)
        #expect(center.asked == 1)
        #expect(center.sent.isEmpty)
    }

    @Test func deniedInSystemSettingsSendsNothing() async throws {
        let center = FakeCenter(.denied)
        let (notifier, _) = try notifier(center)
        #expect(await notifier.deliver(notice) == .notAllowed)
        #expect(center.asked == 0, "the system would not show the question again")
        #expect(center.sent.isEmpty)
    }

    @Test func theSwitchWins() async throws {
        let center = FakeCenter(.allowed)
        let (notifier, _) = try notifier(center, enabled: false)
        #expect(await notifier.deliver(notice) == .switchedOff)
        #expect(center.sent.isEmpty && center.asked == 0)
    }

    @Test func aFailedSendIsReportedAndClearedByTheNextOne() async throws {
        let center = FakeCenter(.allowed)
        center.failure = Boom()
        let (notifier, _) = try notifier(center)
        #expect(await notifier.deliver(notice) == .failed("boom"))
        #expect(notifier.lastSendError == "boom")
        center.failure = nil
        #expect(await notifier.deliver(notice) == .sent)
        #expect(notifier.lastSendError == nil)
    }

    @Test func roomNoticesGoThroughTheSameGate() async throws {
        let center = FakeCenter(.allowed)
        let (notifier, settings) = try notifier(center)
        ShareNotices.notifier = notifier
        defer { ShareNotices.notifier = nil }
        ShareNotices.post(title: "t", body: "b", bench: "/b", identifier: "benchbar.share.x")
        for _ in 0..<50 where center.sent.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(center.sent.map(\.identifier) == ["benchbar.share.x"])
        settings.notificationsEnabled = false
        ShareNotices.post(title: "t", body: "b", bench: "/b", identifier: "benchbar.share.y")
        try await Task.sleep(for: .milliseconds(100))
        #expect(center.sent.count == 1, "the bench notification switch covers room notices too")
    }
}
