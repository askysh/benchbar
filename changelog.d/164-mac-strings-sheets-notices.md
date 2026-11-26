### Mac app

- Sheet titles, notes and results, the crash and room notifications and the update texts are now in the String Catalog, so a language can translate them. The English text is unchanged, except that the bug report result reads "1 line redacted" for one line, not "1 lines redacted" (#164).

### For contributors

- `CatalogueKeysTests` fails when a `String(localized: "...")` key in the Mac app sources is missing from `Localizable.xcstrings` (#164).
