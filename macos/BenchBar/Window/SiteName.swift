import Foundation

/// The rule for a site name, shared by Add Site and the first run wizard.
nonisolated enum SiteName {
    /// The CLI's own rule (fl_site_valid_name).
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, first.isLowercase || first.isNumber else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" || $0 == "." }
    }

    /// What to tell the person when the name breaks the rule.
    static let rule = "Lowercase letters, digits, '-' and '.' only."
}
