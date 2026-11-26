### Mac app

- The app has a String Catalog (`Localizable.xcstrings`) and one place for counts, durations, decimals and dates. Plurals come from the catalogue, so "1 commit" and "2 commits" follow the language's own rules. The English text is unchanged, except that a time limit of one second now reads "1 second" and the free space needed for a shared copy uses the decimal sign of your region (#164).

### For contributors

- Counts, durations, decimals and dates in the Mac app go through `Wording.swift` and the String Catalog; `WordingTests` pins the English and German forms (#164).
