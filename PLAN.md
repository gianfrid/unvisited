# PLAN — Docs drift refresh (recording status, package set, checkbox)

TODO unit: "Technical debt" item 2 (docs drift).

Goal: bring the three docs in line with what recording actually is — a
shipped Android feature — and correct the remaining stale references.

## Implementation steps

1. README.md: the intro's "Active recording is being added now … the
   design is decided" becomes a statement of the shipped feature
   (dashboard, pause/resume, stop-with-name, follow-camera course-up,
   kill-salvage); the Android bullet drops "(in delivery)" and names the
   delivered surface. Desktop-cannot-record stays (already accurate).
2. ARCHITECTURE.md: the recording section heading "(planned slices —
   decided" → "(Android"; the intro sentence "an Android feature in
   delivery" → "an Android feature" noting the section describes what
   has shipped. The slice bullets' content is accurate behavior
   documentation and stays untouched.
3. SPEC.md conventions: the established package set gains `geolocator`
   (agreed in with recording, shipped in slice 2).
4. TODO.md: the malformed `- []` backlog bullet becomes a plain backlog
   bullet (no checkbox — it is parked context, not completable work),
   and this unit's own entry is removed with the commit (renumber).

## Out of scope

No code changes; no wording that changes any rule — status and facts
only. SPEC scope item 6 and the research reports stay as they are.

## Verification

Docs-only: `flutter analyze` and `flutter test` re-run for the slice
discipline (they must be unaffected); the diff reviewed to contain
markdown only.
