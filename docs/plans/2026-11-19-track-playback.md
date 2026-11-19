# Track playback

Implements: —

A playback (replay) function for a stored track, triggered from the track
list's ⋮ menu, with playback-speed control. **The follow-camera must behave
exactly as it does while recording** (the user's explicit priority — it is
also a debug tool for camera movement), which the design guarantees by
*sharing* the recording's follow-camera code, not copying it.

**Worktree**: this branch (`track-playback`, from `origin/slop`) is checked
out at `~/.vibe/worktrees/unvisited-77ace0215c95/track-playback`; the main
checkout stays untouched on `slop`.

## What it does

- The ⋮ menu of a track gains a **Playback** entry (enabled only when the
  track has timestamps — `durationSeconds > 0` — and no recording session
  runs; a track without a timeline can't be replayed).
- Starting playback closes the drawer, fits the camera to the track, arms
  the follow-camera and animates a **marker** along the track's timeline:
  position interpolated between timed points, nose pointing along the
  direction of travel.
- The traveled prefix is drawn as a translucent **trace polyline** (like
  the recording's live trace), so the replay stays readable even where a
  hidden track has no fog circles.
- A compact **playback bar** rides in the bottom overlay column:
  play/pause (replay when finished) · track name · *elapsed / total* · a
  **speed chip** cycling a doubling ladder `1× 2× 4× 8× 16× 32× 64×`
  (default 8×) · the rotation-mode button (the recording chip's, cycling
  the shared `mapRotation` setting) · close.
- The follow-camera is the **recording's**, one module for both: glide
  easing toward each target (τ ≈ 350 ms, per-frame exponential approach,
  settle-and-snap), the below-center framing lead (≤18 % of the screen
  height, capped by the measured bottom overlay column), the zoom floor
  (17), release-on-gesture (drag/multi-finger/fling/double-tap-zoom
  sources only), north-up or course-up per the shared `mapRotation`
  setting with the same rotation math (short-arc rotation, −meanHeading,
  1° course-delta threshold, circular-mean heading smoothing), and the
  marker-rotation publication the course-rotated markers draw against.
- One playback at a time (starting another replaces it); deleting the
  played track stops it; playback is ephemeral UI state — nothing about
  it persists. Pressing play (re)arms the follow after a pause or a
  gesture release, exactly as a locate tap re-arms the session's.

Heading sources differ (the module is fed, not built-in): a session
passes the device's reported heading — with its compass fallback and
stale-fix hold computed by the recording side — while playback passes
the engine's interpolated track course (always known in a timeline; no
compass, no staleness). Speed gates/hysteresis stay recording-only.

Non-goals for v1: scrubbing/seek, per-time stats (altitude/speed
readouts), background/loop modes, playback of the live session.

## Design (following the recording's patterns)

1. **Extract the follow-camera** (slice 1, behavior-preserving):
   `lib/ui/follow_camera.dart` — `FollowCamera`, a plain class owning the
   glide ticker (the hosting widget state supplies `createTicker`), the
   map-event listener (release-on-gesture + rotation publication), and
   the constants now in `RecordingDashboardState` (τ, epsilons, zoom
   floor, lead fraction/margin, gesture source set, smoothing window,
   course-delta threshold, `nearestEquivalentRotation` moves here).
   API: `arm()`, `rearm(pos)`, `release()`, `update(pos, {heading})`
   (records the heading into the circular-mean window, computes the
   framed center and the rotation target, starts the glide), `dispose()`.
   `RecordingDashboardState` keeps the compass subscription, the speed
   hysteresis, the stale-fix hold (a `null` heading passed to `update`
   means "glide position, hold rotation"), the screen latch and the HUD —
   and constructs a `FollowCamera` with them. No visible behavior change;
   the existing recording camera tests (map_page_test) must stay green
   unmodified, proving the extraction preserved semantics.
2. **Pure-Dart engine** — `lib/playback/track_playback.dart`, no Flutter
   imports (the `RecordingSession` pattern). `TrackPlayback`:
   - built from `TrackPoint`s (via `store.loadPoints`): keeps only points
     with timestamps, drops time regressions, is never started for
     fewer than two usable points;
   - state `paused / playing` plus `finished`; **no timer of its own** —
     the page ticks `advance(Duration wallDelta)`, which adds
     `wallDelta × speed` to the progress along the timeline and clamps at
     the end (finished);
   - `position` / `course` getters interpolate lat/lon linearly between
     the two points straddling the progress (monotonic cursor index,
     reset on restart); course = bearing between them (latlong2's
     `Distance().bearing`, pure Dart);
   - the speed ladder, `elapsed`, `total`, `progressFraction`,
     `cycleSpeed`, `restart`, and the played-prefix index for the trace.
3. **Model concern** — `lib/ui/playback_controller.dart`
   (`PlaybackController`, the `RecordingController` pattern, much
   thinner): holds `playback` (engine or null) plus a `playbackLive`
   change-notifier channel (`lib/ui/playback_live.dart`, the
   `RecordingLiveState` pattern); the page's tick notifies it, never the
   model, so replay-rate repaints never rebuild the fog overlay.
   `AppModel` delegates `start/stop/play/pause/restart/cycleSpeed`;
   `stop` is also called on delete of the played track. Starting while a
   session records is prevented at the menu (`enabled: false`).
4. **Trigger** — `track_list.dart`'s popup menu gains the Playback entry
   (icon `play_arrow_outline`); selected → pop the drawer, `start`.
5. **Map page** — `map_page.dart` owns the replay tick (the
   coverage-debounce rule: a model must never hold a timer no page
   listens to): a `Timer.periodic` while playing, advancing with
   wall-clock deltas (capped, so a backgrounded app doesn't jump
   minutes), notifying the live channel and feeding each tick's
   position+course to its `FollowCamera` (the playback dashboard hosts
   it — the recording dashboard's twin; bottom-overlap measured through
   the same `_bottomColumnKey` column, since the playback bar sits in
   it). Start-of-playback fits the track once. Layers, mounted with the
   playback (`model` notification) and rebuilt via the live channel:
   the trace polyline (played prefix) and the course-rotated marker —
   the recording marker's twin, distinct keys (`playback-*`) so tests
   can pin both.
6. **The bar** — `lib/ui/playback_dashboard.dart`, the chip style of the
   recording HUD: listens to the live channel, shows state (icon, times
   via the shared `formatDuration`), drives the controller and the
   rotation-mode button, hosts the playback `FollowCamera`.
7. **Strings** — `app_strings.dart` (en + it; the coverage test fails on
   any untranslated getter): playback menu label, play/pause/replay
   tooltips, speed tooltip, close tooltip. Speed and times render as
   numbers ("8×", "3:21 / 5:40"), no sentences built in the model.

## Steps (commits — one slice each, tests green before the next)

1. **Follow-camera extraction**: `follow_camera.dart` +
   `RecordingDashboard` refactored onto it; all existing tests green
   unmodified.
2. **Engine**: `lib/playback/track_playback.dart` +
   `test/track_playback_test.dart` (timeline math, interpolation,
   speeds, pause/restart/finish, point filtering).
3. **Model + trigger**: `PlaybackController`, `playback_live.dart`,
   `AppModel` wiring, delete-stops-playback +
   `test/playback_controller_test.dart`.
4. **Map + HUD + menu entry**: `track_list.dart` entry (disabled without
   timestamps / while recording), `map_page.dart` tick + follow + layers,
   `playback_dashboard.dart`, strings (en/it), widget tests (menu
   gating, start, HUD controls, speed cycling, course-up rotation, close)
   alongside the existing `map_page_test.dart` fixtures/helpers.

Then: `flutter analyze` clean, `flutter test` green, README/ARCHITECTURE/
SPEC notes for the new replay surface (user-facing in README, design in
ARCHITECTURE), TODO.md untouched (no backlog entry), commit per slice on
`track-playback`.
