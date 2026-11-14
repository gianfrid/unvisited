# Plan — rename app package com.example.unvisited → io.github.gianfrid.unvisited, display name → "UnVisited" (TODO.md "Packaging", item 1)

Single unit, single commit. The TODO says "everywhere it appears", so the
cosmetic `com.example` strings (Windows `CompanyName`/`LegalCopyright`,
macOS `PRODUCT_COPYRIGHT`) are swept in the same commit rather than left
behind.

Target id: `io.github.gianfrid.unvisited`

## Steps

1. **Android**
   - `android/app/build.gradle.kts`: `namespace` and `applicationId` → target id.
   - `git mv android/app/src/main/kotlin/com/example/unvisited/MainActivity.kt`
     → `android/app/src/main/kotlin/io/github/gianfrid/unvisited/MainActivity.kt`
     (create parent dirs first), and update the `package` declaration in the file.
   - `AndroidManifest.xml` needs no change (uses `.MainActivity` and
     `${applicationName}`).

2. **Linux**
   - `linux/CMakeLists.txt`: `APPLICATION_ID` (line 10), the comment on line 132,
     and the `file(COPY ...)` source path on line 143.
   - `git mv linux/com.example.unvisited.desktop`
     → `linux/io.github.gianfrid.unvisited.desktop`; update `StartupWMClass`
     and the comment inside it.
   - `linux/desktop-entry.sh`: both references on lines 25–26.

3. **iOS**
   - `ios/Runner.xcodeproj/project.pbxproj`: 3 × `PRODUCT_BUNDLE_IDENTIFIER =
     com.example.unvisited` → target id; 3 × `...RunnerTests` →
     `io.github.gianfrid.unvisited.RunnerTests`.

4. **macOS**
   - `macos/Runner/Configs/AppInfo.xcconfig`: `PRODUCT_BUNDLE_IDENTIFIER` →
     target id; `PRODUCT_COPYRIGHT` `com.example` → `io.github.gianfrid`.
   - `macos/Runner.xcodeproj/project.pbxproj`: 3 × `...RunnerTests` entries.

5. **Windows (cosmetic sweep)**
   - `windows/runner/Runner.rc`: `CompanyName` and `LegalCopyright`.

6. **Display name → "UnVisited"** (display strings only; binary/executable
   names stay lowercase — they are identifiers, not names)
   - `android/app/src/main/AndroidManifest.xml`: `android:label` → `UnVisited`.
   - `ios/Runner/Info.plist`: `CFBundleDisplayName` `Unvisited` → `UnVisited`;
     `CFBundleName` `unvisited` → `UnVisited`.
   - `macos/Runner/Configs/AppInfo.xcconfig`: `PRODUCT_NAME` → `UnVisited`
     (macOS `CFBundleName` is `$(PRODUCT_NAME)`).
   - `linux/io.github.gianfrid.unvisited.desktop` (renamed in step 2):
     `Name=Unvisited` → `UnVisited`. `Exec`/`Icon` stay `unvisited`.
   - `windows/runner/Runner.rc`: `FileDescription`, `InternalName`,
     `ProductName` → `UnVisited`. `OriginalFilename` `unvisited.exe` stays.

7. **Verify**
   - `grep -rn "com.example"` over the repo (excluding `build/`, `.dart_tool/`,
     `.gradle/`, `.git/`) returns only this plan, TODO.md, and git history.
   - `grep -rn "Unvisited\|\"unvisited\""` on the touched platform files shows
     only the intended `UnVisited` display strings.
   - `flutter analyze` — clean.
   - `flutter test` — pass.
   - `flutter build apk --debug` — succeeds (exercises namespace + Kotlin
     package + manifest merge together).

8. **Commit** all of the above plus this PLAN.md, and remove the completed
   Packaging item from TODO.md in the same commit.

## Notes / assumptions

- `applicationId` change means an already-installed debug build installs as a
  fresh app rather than upgrading in place — irrelevant for development.
- Linux desktop build (`flutter build linux`) is not run here; the CMake
  install path coupling is covered by the grep check and a manual build if
  desired.
- No Dart code references the package id (verified: `lib/` is clean).
