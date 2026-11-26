import Foundation

/// The shared wording of counts, durations, decimals and dates. One place, so the plural
/// rules come from the String Catalog (Localizable.xcstrings) and the numbers and dates from
/// the system formatters, and a second language needs no change to the callers.
/// The English text is the same as the hand built text it replaced.
nonisolated enum Wording {
    // MARK: counts (plural variations in the catalogue)

    static func commits(_ n: Int) -> String { String(localized: "\(n) commits") }
    static func days(_ n: Int) -> String { String(localized: "\(n) days") }
    static func sites(_ n: Int) -> String { String(localized: "\(n) sites") }
    static func guests(_ n: Int) -> String { String(localized: "\(n) guests") }
    static func benches(_ n: Int) -> String { String(localized: "\(n) benches") }
    static func failures(_ n: Int) -> String { String(localized: "\(n) failures") }
    static func warnings(_ n: Int) -> String { String(localized: "\(n) warnings") }
    static func peopleAre(_ n: Int) -> String { String(localized: "\(n) people are") }
    static func sharingEndsIn(minutes n: Int) -> String { String(localized: "Sharing ends in \(n) minutes") }

    // MARK: durations (the compact "2 h 05 min" form of the app, not the long system form)

    /// "41 s", "1 min 35 s", "1 h 05 min".
    static func elapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return String(localized: "\(s) s") }
        if s < 3600 { return String(localized: "\(s / 60) min \(twoDigits(s % 60)) s") }
        return String(localized: "\(s / 3600) h \(twoDigits((s % 3600) / 60)) min")
    }

    /// "59 min", "2 h", "2 h 1 min", "less than a minute".
    static func countdown(_ seconds: Int) -> String {
        guard seconds >= 60 else { return String(localized: "less than a minute") }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours == 0 { return String(localized: "\(minutes) min") }
        return minutes == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(minutes) min")
    }

    /// "45s", "12m", "3h 05m", "2d 4h".
    static func uptime(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let totalMinutes = s / 60, totalHours = totalMinutes / 60, totalDays = totalHours / 24
        if totalDays > 0 { return String(localized: "\(totalDays)d \(totalHours % 24)h") }
        if totalHours > 0 { return String(localized: "\(totalHours)h \(twoDigits(totalMinutes % 60))m") }
        if totalMinutes > 0 { return String(localized: "\(totalMinutes)m") }
        return String(localized: "\(s)s")
    }

    /// "2 h 5 min left", "59 min left".
    static func timeLeft(minutes: Int) -> String {
        minutes >= 60 ? String(localized: "\(minutes / 60) h \(minutes % 60) min left") : String(localized: "\(minutes) min left")
    }

    /// "5 minutes", "30 seconds".
    static func timeout(seconds: Int) -> String {
        seconds >= 120 ? String(localized: "\(seconds / 60) minutes") : String(localized: "\(seconds) seconds")
    }

    /// "4 h", for a picker row.
    static func hoursShort(_ n: Int) -> String { String(localized: "\(n) h") }

    /// Two digits with a leading zero, in plain ASCII digits (a clock, not a quantity).
    private static func twoDigits(_ n: Int) -> String { String(format: "%02d", n) }

    // MARK: decimals

    /// One decimal place in the locale's own form: "2.5" in English, "2,5" in German.
    static func oneDecimal(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// "Needs about 2.5 GB free".
    static func needs(gigabytes: Double, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: "Needs about \(oneDecimal(gigabytes, locale: locale)) GB free")
    }

    // MARK: dates

    /// "Nov 19, 2026 at 3:20 PM" in the user's form.
    static func dayAndTime(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
    }

    /// "3:20 PM" in the user's form.
    static func time(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }

    /// The time alone for a moment on `now`'s day, else the day and the time.
    static func timeOrDayAndTime(_ date: Date, now: Date, calendar: Calendar = .current,
                                 locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? time(date, locale: locale, timeZone: timeZone)
            : dayAndTime(date, locale: locale, timeZone: timeZone)
    }
}
