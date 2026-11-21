# Map controls rework: edge button clusters for handlebar use

Implements: —

Reworks the map HUD from a full-height zoom slider + bottom-left action
pill into two edge clusters sized for a phone on a handlebar/case strap:

```
        [toolbar]
                         [ctrl pill, configured edge]
 [record cluster,          [north/course]
  opposite edge,           [ + ]
  vertically centered]     [ − ]
                           [locate]
   (bottom column: road chip, selection bar, recording HUD, stats, playback)
```

## Rationale (research, 2026-11-21)

- Dedicated bike computers (Garmin Edge, Wahoo ELEMNT, Hammerhead Karoo)
  put record start/stop and map zoom on *physical* buttons; on-screen map
  controls shrink to tiny icons. Lesson: while riding, critical actions
  must be big and edge-anchored, not precise touch targets.
- Phone map apps converge on the same pattern: OsmAnd stacks zoom +/−,
  my-location and compass buttons on a screen edge (since 4.9 assignable
  to a four-corner grid, appearance customizable); Komoot re-added +/− zoom
  buttons on the navigation map with a "cycling only" visibility option;
  Gaia pins locate to a bottom corner; Strava keeps record as a prominent
  bottom control. Locus Map (popular for handlebar mounts) has fully
  customizable side/bottom panels, and has explicit user requests for a
  "bicycle UI" with bigger, movable buttons because handlebar shake makes
  small corner buttons hard to hit.
- "Customizable HUD" in this ecosystem means corner-grid assignment +
  panel arrangement (OsmAnd/Locus), not free-drag (older OsmAnd long-press
  drag was dropped for accidental moves). So this rework lays the clusters
  out as data (edge + order), leaving corner assignment as a cheap
  follow-up setting.

## Decisions

1. Zoom = two buttons (`+`/`−`) only; the draggable rail goes away.
   Pinch/wheel/double-tap/keyboard still zoom (unchanged).
2. Edge pill order top→bottom: north/course toggle, `+`, `−`, locate.
3. Record cluster (record/pause/resume, stop above when paused) moves to
   the *opposite* edge, vertically centered. It stays hidden until a real
   fix has arrived (`gpsWorking`) on location-supporting platforms.
4. Rotation toggle becomes a single global control in the pill; it is
   removed from the recording HUD chip and the playback bar. The Settings
   segment stays.
5. The `zoomSliderSide` setting becomes "control side" (UI label only;
   storage key unchanged for compat). The pill follows it, the record
   cluster mirrors to the other edge.
6. Bottom column keeps: road chip, selection bar, recording HUD chip +
   stats, playback bar. The action stack leaves it.

## Slices (each committed once analyze+tests pass)

1. **Zoom pill.** Replace `lib/ui/zoom_slider.dart` with
   `lib/ui/map_controls.dart` hosting a `MapControlPill` (north, +, −,
   locate buttons in one surface-colored rounded column). Keep
   `mapMinZoom`/`mapMaxZoom` and the camera-move logic (`_moveTo` clamp);
   delete the rail/thumb/drag code. New widget keys: `rotation-mode-button`
   (moved here), `zoom-in-button`, `zoom-out-button`, `locate-button`.
   Buttons keep tooltips `strings.zoomIn`/`zoomOut`/`strings.locateTooltip`/
   `rotationModeName`.
2. **Locate + rotation into the pill.** Move the locate action (spinner
   state included) out of `BottomActionStack` into the pill under `−`;
   move the rotation-mode toggle out of `recording_dashboard.dart` and
   `playback_dashboard.dart` into the pill above `+`. `map_page.dart`
   passes `locating`/`onLocate` to the pill instead of the action stack.
3. **Record cluster to the opposite edge.** `BottomActionStack` becomes a
   record-only cluster (stop above pause/resume/record, unchanged logic),
   positioned mid-edge opposite the pill in `map_page.dart`; the bottom
   column drops it. Keep the `locationSupported` gate. Check
   `bottomOverlap`/follow-camera framing still only measures the bottom
   column.
4. **Settings + strings.** Rename the Settings label
   (`zoomSlider`/`zoomSliderSubtitle` → "Control side" wording) in
   `app_strings.dart` for all locales; keep storage key `zoomSliderSide`.
5. **Tests.** Update `test/map_page_test.dart` (replace `zoom-track` drag
   tests with zoom-button taps; pill hugs configured edge; settings sheet
   label), `test/playback_widget_test.dart` (rail-drag ride-zoom test →
   repeated zoom-out taps), recording/playback dashboard tests
   (`rotation-mode-button` now on the map, not the chip/bar). Add tests:
   pill order (north,+,−,locate), record cluster on the opposite edge and
   hidden without a fix, locate under `−`.
6. **Docs.** Update README.md module list (`zoom_slider.dart` →
   `map_controls.dart`) and ARCHITECTURE.md (zoom-slider edge → control
   side; bottom-left action stack → opposite-edge record cluster; rotation
   button location).

## Verification

- `flutter analyze` clean; `flutter test` green (all suites).
- Manual check on desktop (`flutter run -d linux`) + note for an Android
  handlebar smoke test.
- Push `map-controls-rework`, open PR to `slop` with `gh pr create`,
  body summarizing the layout change and the research rationale.
