import Foundation
import Testing
@testable import BenchBar

/// The shared wording of counts, durations, decimals and dates (Wording.swift). The plural
/// forms come from the String Catalog, so these tests also fail when the catalogue is not
/// in the app bundle or a key is spelled differently from the code.
@Suite("Wording")
struct WordingTests {
    private let german = Locale(identifier: "de_DE")
    private let english = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    /// 2026-11-19 15:20:00 UTC.
    private var moment: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 15, minute: 20))!
    }

    /// Recent systems write a narrow no break space before AM and PM.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: counts

    @Test func countsUseTheCataloguePluralForms() {
        #expect(Wording.commits(0) == "0 commits")
        #expect(Wording.commits(1) == "1 commit")
        #expect(Wording.commits(2) == "2 commits")
        #expect(Wording.days(1) == "1 day")
        #expect(Wording.days(12) == "12 days")
        #expect(Wording.sites(1) == "1 site")
        #expect(Wording.sites(3) == "3 sites")
        #expect(Wording.guests(1) == "1 guest")
        #expect(Wording.guests(2) == "2 guests")
        #expect(Wording.benches(1) == "1 bench")
        #expect(Wording.benches(2) == "2 benches")
        #expect(Wording.failures(1) == "1 failure")
        #expect(Wording.warnings(2) == "2 warnings")
        #expect(Wording.peopleAre(1) == "1 person is")
        #expect(Wording.peopleAre(2) == "2 people are")
        #expect(Wording.sharingEndsIn(minutes: 1) == "Sharing ends in 1 minute")
        #expect(Wording.sharingEndsIn(minutes: 10) == "Sharing ends in 10 minutes")
    }

    // MARK: durations

    @Test func elapsedKeepsTheCompactForm() {
        #expect(Wording.elapsed(-3) == "0 s")
        #expect(Wording.elapsed(41) == "41 s")
        #expect(Wording.elapsed(95) == "1 min 35 s")
        #expect(Wording.elapsed(3900) == "1 h 05 min")
    }

    @Test func countdownKeepsTheCompactForm() {
        #expect(Wording.countdown(30) == "less than a minute")
        #expect(Wording.countdown(3540) == "59 min")
        #expect(Wording.countdown(7200) == "2 h")
        #expect(Wording.countdown(7260) == "2 h 1 min")
    }

    @Test func uptimeAndTimeLeft() {
        #expect(Wording.uptime(-5) == "0s")
        #expect(Wording.uptime(45) == "45s")
        #expect(Wording.uptime(3 * 3600 + 5 * 60) == "3h 05m")
        #expect(Wording.uptime(2 * 86400 + 4 * 3600 + 59) == "2d 4h")
        #expect(Wording.timeLeft(minutes: 59) == "59 min left")
        #expect(Wording.timeLeft(minutes: 125) == "2 h 5 min left")
        #expect(Wording.hoursShort(4) == "4 h")
    }

    @Test func aTimeLimitOfOneSecondIsNotPlural() {
        #expect(Wording.timeout(seconds: 1) == "1 second")
        #expect(Wording.timeout(seconds: 30) == "30 seconds")
        #expect(Wording.timeout(seconds: 300) == "5 minutes")
    }

    // MARK: decimals

    @Test func oneDecimalFollowsTheLocale() {
        #expect(Wording.oneDecimal(2.5, locale: english) == "2.5")
        #expect(Wording.oneDecimal(12, locale: english) == "12.0")
        #expect(Wording.oneDecimal(2.5, locale: german) == "2,5")
        #expect(Wording.oneDecimal(12, locale: german) == "12,0")
        #expect(Wording.needs(gigabytes: 2.5, locale: english) == "Needs about 2.5 GB free")
        #expect(Wording.needs(gigabytes: 2.5, locale: german) == "Needs about 2,5 GB free")
    }

    // MARK: dates

    @Test func theTimeFollowsTheLocale() {
        #expect(plain(Wording.time(moment, locale: english, timeZone: utc)) == "3:20 PM")
        #expect(plain(Wording.time(moment, locale: german, timeZone: utc)) == "15:20")
    }

    @Test func theDayAndTimeFollowTheLocale() {
        let en = plain(Wording.dayAndTime(moment, locale: english, timeZone: utc))
        #expect(en.contains("Nov") && en.contains("19") && en.contains("2026") && en.contains("3:20 PM"))
        let de = plain(Wording.dayAndTime(moment, locale: german, timeZone: utc))
        #expect(de.contains("19") && de.contains("2026") && de.contains("15:20"))
        #expect(!de.contains("PM"))
    }

    @Test func aMomentOnTheSameDayShowsOnlyTheTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let morning = moment.addingTimeInterval(-6 * 3600)
        let sameDay = plain(Wording.timeOrDayAndTime(moment, now: morning, calendar: calendar, locale: english, timeZone: utc))
        #expect(sameDay == "3:20 PM")
        let otherDay = plain(Wording.timeOrDayAndTime(moment, now: morning.addingTimeInterval(-86400), calendar: calendar, locale: english, timeZone: utc))
        #expect(otherDay.contains("19") && otherDay.contains("3:20 PM") && otherDay != "3:20 PM")
    }
}
