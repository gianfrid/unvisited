# Plan — pubspec cleanup (TODO.md, technical debt item 3)

## Change

`pubspec.yaml` only:

1. Drop the Flutter template comment block (versioning lecture, dependency
   boilerplate, assets/fonts tutorial comments). Keep: name, description
   rewritten from "A new Flutter project." → a real one-liner, publish_to,
   version, environment, dependencies, dev_dependencies, the flutter
   section with `uses-material-design: true`.
2. Remove the unused `cupertino_icons` dependency — verified: no
   CupertinoIcons usage anywhere in lib/ or test/; the
   `package:flutter/cupertino.dart` import in main.dart is the locale
   delegate and stays untouched.

Per SPEC, the package removal needs the owner's explicit confirmation in
this plan step — that confirmation is being asked for now.

## Verification

`flutter analyze` clean, `flutter test` green
(`flutter pub get` re-resolves without cupertino_icons).

## Commit

PLAN.md, pubspec.yaml, pubspec.lock, and TODO.md's item 3 removed (list
renumbered) in one commit.
