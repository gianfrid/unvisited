# Bottom column order: new bars anchored at the bottom edge

## Problem (user-tested)
In `MapPage`'s bottom `Positioned(bottom: 0)` column the order is:
SelectionBar -> RecordingDashboard -> RecordingSpeedReadout ->
BottomActionStack. So while recording (or with an aggregate selected) the
new bars stack *above* the record/locate action stack, pushing the speed
readout toward mid-screen; the new bars are not at the bottom edge.

## Change
In `lib/ui/map_page.dart` (~line 790 column children), move the
`BottomActionStack` block to be the FIRST child of the column and let the
selection bar / recording chip / speed readout follow it, so the new bars
end at the bottom edge (bottom: 0). When idle (no selection, no session)
only the action stack renders and it still sits at the bottom edge, since
the column is `mainAxisSize: MainAxisSize.min` inside `bottom: 0`.

No widget code changes; only child order in the one column.

## Verification
- `flutter analyze` clean, `flutter test` passes
- Manual/desktop check: record button bar stays bottom-left when idle;
  while recording the chip + speed sit at the very bottom, action stack
  above them.
