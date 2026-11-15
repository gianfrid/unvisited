# Trim the *.md files: dedup, history, and code-verified corrections

Approved by the user after a docs-vs-code audit (read-only child agent) plus a
grilled design tree. Nothing is applied before this plan is confirmed.

## Changes

1. **SPEC.md**
   - Scope item 6 (recording): strip the design narrative, keep a short scope
     statement; the invariants stay in the "Hard rules → Recording" section and
     the design lives in ARCHITECTURE.md.
   - Conventions: remove the stale "~40 strings" count (the class declares 98).
   - Format priority: drop the "plain KML is handled alongside KMZ" claim —
     the wired parser list has no KML parser (code-verified contradiction).

2. **ARCHITECTURE.md**
   - Recording section: replace the "slice 1–4" shipped-history bullets with
     present-tense component descriptions (engine, Android session, dashboard,
     robustness), per AGENTS.md rule that built history belongs in commits.
   - Align the course-up rotation text with the code: rotation follows the
     device-reported heading (compass substitute below 1 m/s), not a bridged
     bearing (`recording_dashboard.dart:249-270`).
   - Drop the never-implemented "chip's screen-lock icon" opt-out sentence —
     the screen latch is controlled only by the Settings switch.
   - Fix the caching misattribution: `tile_source.dart` holds only URL
     templates; the caching provider is wired in `map_page.dart`.
   - `kmz_parser.dart` bullet and the OpenTracks bullet: drop the plain-KML
     claims (KMZ only).

3. **README.md**
   - Drop the "How this project is documented" section (AGENTS.md owns the
     doc map).
   - Formats line: `KMZ/KML` → `KMZ`.

4. **AGENTS.md**
   - Quick reference: drop "cross-format dedup is future work" (implemented in
     `track_store.dart:516-551`, specified in SPEC.md); point at SPEC.md
     instead of restating the rule.
   - Add an anti-drift note: when the quick reference and SPEC.md disagree,
     SPEC.md wins.
   - Priority list: drop "(plain KML alongside KMZ)".

5. **PLAN.md / TODO.md / BACKLOG.md** — PLAN.md is this file (overwritten per
   its lifecycle rule); TODO.md and BACKLOG.md untouched.

## Verification

- `flutter analyze` clean, `flutter test` passes (docs-only change, but run
  both per repo rules).
- Commit PLAN.md + the doc edits together.
