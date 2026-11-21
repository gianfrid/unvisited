# Playback bar: split the stacked duration/speed column (PR #4 feedback)

Implements: — (follow-up to `docs/plans/2026-11-21-control-pill-polish.md`, PR #4)

The replay bar's second row stacks "elapsed / total" over the instant
speed in one right-aligned column crammed next to the track name. Split
them onto one baseline:

```
before:  [Name] 12 [elapsed/total]   [spacer]           [1×]
                    [12.3 km/h]  ← stacked under duration
after:   [Name] 12 [elapsed / total] [spacer] [12.3 km/h] 8 [1×]
```

Change is confined to `_PlaybackDashboardState._bar`'s second row in
`lib/ui/playback_dashboard.dart`: the `Column` becomes a single duration
`Text`, and the instant-speed `Text` (key `playback-instant-speed`
unchanged) moves before the speed chip on the right. Both keep tabular
figures. Tests: the existing pace/dash and narrow-surface tests cover the
keys; no layout assertion changes expected. Verify with `flutter analyze`,
`flutter test`, and a golden render of the bar; commit on
`map-controls-rework` (PR #4 updates).
