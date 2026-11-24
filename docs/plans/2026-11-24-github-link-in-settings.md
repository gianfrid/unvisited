# GitHub link in the Settings screen

Implements: —

## Goal

The Settings sheet's About card gets a tappable link to the project's GitHub
repository (`https://github.com/gianfrid/unvisited`, the `repository:` URL in
pubspec.yaml). Tapping it opens the URL in the system browser.

## Steps

1. **Strings** (`lib/l10n/app_strings.dart`): add one getter
   `githubRepository` to the abstract class plus English
   ("GitHub repository") and Italian ("Repository GitHub") overrides, next to
   the other Settings/About strings. The URL itself is a `const`, not a
   localized string. Register the key in `test/app_strings_test.dart`'s
   `allStrings` map so the coverage test enforces both translations.
2. **Settings sheet** (`lib/ui/settings_sheet.dart`): in the About card, under
   the build-date line, add an tappable row (icon `Icons.code`/`open_in_new`
   + label from `strings.githubRepository`, showing the URL) that calls the
   URL opener. A `const repoUrl = 'https://github.com/gianfrid/unvisited'`
   lives at the top of the file.
3. **URL opener — decided: (a), the `url_launcher` package.** Confirmed with
   the user after asking (the AGENTS.md package list requires that ask).
   First-party Flutter package, opens the system browser on Android and the
   desktops without bespoke platform-channel code. Android 11+ package
   visibility needs an `ACTION_VIEW` https `<queries>` intent in
   `AndroidManifest.xml` alongside the existing PROCESS_TEXT one.
4. **Tests**: extend the settings-sheet widget test in
   `test/map_page_test.dart` to expect the GitHub link row; the strings
   coverage test picks up the new key automatically.
5. **Verify**: `flutter analyze` clean, `flutter test` green.
