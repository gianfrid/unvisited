Implements: —

# Archive task plans under `docs/plans/` and add a trivial fast-lane

1. Move the standing `PLAN.md` (the plan of commit 0cc6408, "Reject
   speed-outlier fixes in the recording engine") to
   `docs/plans/2026-11-15-reject-speed-outlier-fixes.md`, content unchanged.
2. AGENTS.md Task workflow: plans become one immutable file per task at
   `docs/plans/<date>-<slug>.md`, whose first line links the work
   (`Implements: TODO.md #<n>`, or `Implements: —` when there is no TODO
   entry). Plan files are never edited after their commit; a revised plan
   is a new file.
3. AGENTS.md Task workflow: define the trivial fast-lane that skips the
   plan — doc-only edits, typo fixes, mechanical regeneration of committed
   artifacts with their own tool. Anything changing behavior in `lib/`,
   `android/`, tests, or dependencies is non-trivial.
4. Update guideline 0 and the commit-message rule to reference
   `docs/plans/` instead of the single overwritten PLAN.md.
5. Write this plan file itself, per the new rule.

## Verification

- `flutter analyze` clean, `flutter test` passes.
- All of the above committed together; working tree clean.
