# Remove the orphaned `infoTitle` localization string

Implements: — (cruft audit follow-up, no backlog entry)

## Finding

The strings audit (previous slice's report) found `infoTitle` orphaned
since its birth: a07fded ("Track info dialog", Nov 14) declared it,
translated it ("Track info" / "Info traccia") and added it to the
strings-coverage test, but shipped the dialog without a title — the ⋮
menu entry uses `trackMenuInfo` and no widget ever referenced
`strings.infoTitle`. Two translations plus the coverage entry are being
maintained for a dead string. Not from the marker-fix lineage; the only
dead code the audit found. The other `info*` labels (infoStart,
infoFormat, infoPoints, infoDuration, infoDistance) are live.

## Change

Delete, in one slice:

- `lib/l10n/app_strings.dart`: the abstract `String get infoTitle;`
  declaration and the en/`it` overrides (each with its `@override`).
  The section's comment ("The track info dialog's labels") stays — the
  other labels are live.
- `test/app_strings_test.dart`: the `'infoTitle': s.infoTitle,` entry
  in the coverage map.

## Verification

`flutter analyze` clean (no unused-string members elsewhere), the
strings coverage test green in both languages, full `flutter test`
green. No behavior change: no widget reads the string.
