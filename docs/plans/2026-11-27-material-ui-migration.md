# Migrate to material_ui / cupertino_ui

Implements: —

## Problem

The environment's Flutter (now 3.50.1 stable) deprecates the umbrella
libraries: `package:flutter/material.dart` and
`package:flutter/cupertino.dart`. `flutter analyze` reports 21
`deprecated_member_use` infos across the repo (every Material/Cupertino
import), breaking the "analyzer clean" invariant through no fault of
the app's code.

## Approach

Mechanical, tool-driven — the analyzer ships a fix for every instance
(`dart fix`): the 21 import swaps
(`flutter/material.dart` → `material_ui/material_ui.dart`,
`flutter/cupertino.dart` → `cupertino_ui/cupertino_ui.dart`) plus one
`missing_dependency` fix adding the packages to `pubspec.yaml`
(direct dependencies, matching versions already resolved in the pub
cache: material_ui 1.11.x, cupertino_ui 1.1.x — the official Flutter
libraries relocated into packages, re-exporting `flutter/widgets.dart`).

Package additions are AGENTS-gated, but this migration is exactly the
change commissioned in conversation; nothing else is added.

## Steps

1. `dart fix --apply` (all 22 fixes: 21 imports, 1 pubspec dependency).
2. `flutter pub get` to resolve.
3. `flutter analyze` — the 21 infos gone, nothing new.
4. `flutter test` — full offline suite green (the widget tests are the
   real compatibility check: every Material widget the app and its
   tests use must resolve identically through the new packages).
5. Commit everything together with this plan.

## Verification

Analyzer clean; full test suite green; no hand edits beyond what the
fix tool produced.

## Commit

One slice, one commit: the tool's rewrites, pubspec.yaml (+lock),
this plan file.
