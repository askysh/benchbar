import Foundation
import Testing
@testable import BenchBar

@Suite("Share presentation")
struct SharePresentationTests {
    private let copy = ShareCopy(made: "2026-11-03T08:40:00Z", sourceSite: "site1.localhost", ageS: 1200)
    private let red = SharePreflight(ok: false, checks: [ShareCheck(id: "local_network", status: .fail, fixAction: .openLocalNetworkSettings)])
    private let green = SharePreflight(ok: true, checks: [ShareCheck(id: "pf_active", status: .ok)])

    @Test func onePrimaryButtonPerState() {
        #expect(SharePrimary.from(ShareStatus(state: .off)) == .setUp)
        #expect(SharePrimary.from(ShareStatus(state: .off, copy: copy, lanGuard: .missing)) == .turnOnProtection)
        #expect(SharePrimary.from(ShareStatus(state: .off, copy: copy, lanGuard: .outdated)) == .turnOnProtection)
        #expect(SharePrimary.from(ShareStatus(state: .off, copy: copy, preflight: red)) == .start(enabled: false))
        #expect(SharePrimary.from(ShareStatus(state: .off, copy: copy, preflight: green)) == .start(enabled: true))
        #expect(SharePrimary.from(ShareStatus(state: .on, copy: copy)) == .stop)
        #expect(SharePrimary.from(ShareStatus(protocolVersion: 2, state: .off)) == .updateCLI)
    }

    @Test func checksOfTheRunningShareDoNotBlockAStart() {
        let webDown = SharePreflight(ok: false, checks: [
            ShareCheck(id: "pf_active", status: .ok),
            ShareCheck(id: "gateway_reachable", status: .skip),
            ShareCheck(id: "share_traceback_off", status: .fail, fixAction: .restartSharing),
            ShareCheck(id: "share_debugger_off", status: .fail, fixAction: .restartSharing),
        ])
        for state in [ShareState.off, .expired] {
            let status = ShareStatus(state: state, copy: copy, preflight: webDown)
            #expect(SharePrimary.from(status) == .start(enabled: true))
            #expect(webDown.checks.filter { SharePresentation.waitsForStart($0, status) }.map(\.id)
                == ["gateway_reachable", "share_traceback_off", "share_debugger_off"])
        }
        let on = ShareStatus(state: .on, copy: copy, preflight: webDown)
        #expect(!webDown.checks.contains { SharePresentation.waitsForStart($0, on) })
    }

    @Test func aRefusedSetupSaysWhy() {
        let done = #"{"event":"done","exit":1,"changed":[],"error":"Sharing setup was interrupted."}"#
        #expect(ShareStepLine.failure([done]) == "Sharing setup was interrupted.")
        // a failed step's [FAIL] line beats the done line, which only names the step
        let step = #"{"event":"step","id":"restore","status":"failed","message":"[FAIL] no complete database backup with the stamp 20261103_084000"}"#
        let stopped = #"{"event":"done","exit":1,"error":"share setup stopped at: Restore the copy."}"#
        #expect(ShareStepLine.failure([step, stopped]) == "no complete database backup with the stamp 20261103_084000")
        #expect(ShareStepLine.failure([#"{"event":"step","id":"restore","status":"failed"}"#, stopped]) == "share setup stopped at: Restore the copy.")
        #expect(ShareStepLine.failure([#"{"event":"done","exit":0}"#]) == nil)
    }

    @Test func countdownAndIndicator() {
        #expect(SharePresentation.countdown(30) == "less than a minute")
        #expect(SharePresentation.countdown(3540) == "59 min")
        #expect(SharePresentation.countdown(7200) == "2 h")
        #expect(SharePresentation.countdown(7260) == "2 h 1 min")
        #expect(SharePresentation.indicator(ShareStatus(state: .on, secondsLeft: 3540, devicesOnline: 0)) == "Sharing on your network · 0 online · 59 min left")
        #expect(SharePresentation.indicator(ShareStatus(state: .on, secondsLeft: 3540, devicesOnline: 3)) == "Sharing on your network · 3 online · 59 min left")
    }

    @Test func everyFixActionButNoneHasAButtonAndNoCLIText() {
        for action in ShareFixAction.allCases where action != .none {
            let label = try? #require(SharePresentation.fixLabel(action))
            #expect(label?.contains("benchbar") == false)
            #expect(label?.contains("_") == false)
        }
        #expect(SharePresentation.fixLabel(.none) == nil)
    }

    @Test func protectionRowAndStopConfirm() {
        #expect(SharePresentation.protectionText(.installed) == "Network protection is on.")
        #expect(SharePresentation.protectionText(.missing).hasPrefix("Network protection is off."))
        #expect(SharePresentation.protectionText(.outdated) == "Network protection needs an update.")
        #expect(SharePresentation.stopConfirm(online: 0) == "Stop sharing?")
        #expect(SharePresentation.stopConfirm(online: 3) == "Stop sharing? 3 people are connected and will be signed out.")
    }

    @Test func restartConfirmCountsThePeopleItSignsOut() {
        #expect(SharePresentation.restartConfirm(online: 0).message == "Restart sharing?")
        #expect(SharePresentation.restartConfirm(online: 1).message == "Restart sharing? 1 person is connected and will be signed out.")
        #expect(SharePresentation.restartConfirm(online: 4).message == "Restart sharing? 4 people are connected and will be signed out.")
        #expect(SharePresentation.restartConfirm(online: 4).detail.contains("new room code"))
    }

    @Test func extendNeverPassesTheCap() {
        #expect(SharePresentation.extendOptions(canExtendS: 0).isEmpty)
        #expect(SharePresentation.extendOptions(canExtendS: 1800).map(\.minutes) == [30])
        #expect(SharePresentation.extendOptions(canExtendS: 7200).map(\.minutes) == [30, 60])
    }

    @Test func peopleSortOnlineFirstThenLastSeen() {
        let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
        let people = [SharePerson(id: "d_1", name: "A", online: false, lastSeen: late),
                      SharePerson(id: "d_2", name: "B", online: true, lastSeen: early),
                      SharePerson(id: "d_3", name: "C", online: true, lastSeen: late)]
        #expect(SharePresentation.sorted(people).map(\.id) == ["d_3", "d_2", "d_1"])
    }

    @Test func setupNeedsPeopleTheAcknowledgementAndDisk() {
        var form = ShareSetupForm(site: "site1.localhost")
        #expect(!form.canRun)
        form.picked = ["priya@example.com"]
        #expect(!form.canRun)
        form.acknowledged = true
        #expect(form.canRun)
        form.freeGB = 1; form.neededGB = 2
        #expect(form.shortOnDisk && !form.canRun)
        #expect(form.request(refresh: false).arguments == ["--site", "site1.localhost", "--users", "priya@example.com", "--backup-now"])
    }

    @Test func lockLineBudgetWins() {
        #expect(SharePresentation.lockLine(ShareStatus(state: .on, locked: true, lockReason: .budget, budgetLeft: 0)) == SharePresentation.budgetLocked)
        #expect(SharePresentation.lockLine(ShareStatus(state: .on, locked: true, lockReason: .full)) == SharePresentation.full)
        #expect(SharePresentation.lockLine(ShareStatus(state: .on, locked: true, lockReason: .host)) == SharePresentation.locked)
        #expect(SharePresentation.lockLine(ShareStatus(state: .on, locked: false, budgetLeft: 10)) == nil)
    }

    @Test func noUIStringUsesInternalWords() {
        let strings = [SharePresentation.newerCLI, SharePresentation.codeNote, SharePresentation.liveUpdates, SharePresentation.awake,
                       SharePresentation.locked, SharePresentation.full, SharePresentation.budgetLocked, SharePresentation.joinTrouble,
                       SharePresentation.wipeOwed, SharePresentation.acknowledgement, SharePresentation.refreshConfirm,
                       SharePresentation.peopleTitle, SharePresentation.driftWarning]
            + ShareFixAction.allCases.compactMap(SharePresentation.fixLabel)
            + [LanGuardState.installed, .missing, .outdated].map(SharePresentation.protectionText)
        for text in strings {
            for word in ["fp8", "preflight", "LAN guard", "Revoke", "Devices", "pair"] { #expect(!text.contains(word), "\(text) has \(word)") }
        }
    }

    @Test func moveTargetsAreKnownSeatsNobodyHolds() {
        let sam = SharePerson(id: "d_1", name: "Sam", seatID: "s_a", seatFullName: "Sam Rao")
        let asha = SharePerson(id: "d_2", name: "Asha", seatID: "s_b", seatFullName: "Asha K")
        let known = ["s_a": "Sam Rao", "s_b": "Asha K", "s_c": "Priya Nair"]
        #expect(SharePresentation.moveTargets(for: sam, people: [sam, asha], known: known).map(\.id) == ["s_c"])
        #expect(SharePresentation.moveTargets(for: sam, people: [sam], known: known).map(\.id) == ["s_b", "s_c"])
        #expect(SharePresentation.moveTargets(for: sam, people: [sam], known: ["s_a": "Sam Rao"]).isEmpty)
    }
}
