# Bump three locked minor dependencies in pubspec.lock

Implements: —

`flutter pub outdated` flags 7 packages; 4 are blocked by Flutter SDK /
file_picker constraints (geolocator 14.1.2, cross_file 0.4.0,
material_color_utilities 0.13.1, test_api 0.7.15) and stay put. The other
3 are locked in pubspec.lock to older versions but within our declared
constraints and safely upgradable:

- archive 4.6.0 -> 4.7.1 (direct, constraint ^4.6.0)
- android_file_picker 2.1.5 -> 2.1.6 (transitive via file_picker)
- vector_math 2.4.0 -> 2.4.4 (transitive via flutter_map)

Steps:
1. `flutter pub upgrade archive android_file_picker vector_math`
2. `flutter analyze` must be clean, `flutter test` must pass (315 tests)
3. Commit the plan file + pubspec.lock change only; no pubspec.yaml or code
   changes expected.
