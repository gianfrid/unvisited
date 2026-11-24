# Member bubble: content-sized, bottom-anchored with a leader tip

Implements: —

Small polish on the member-picking bubble (61819eb): the user reports the
popup spacing is off. Cause: the bubble is a fixed 158 px-tall box
anchored at a fixed −170 px offset above the tap, so a one-button ghost
bubble carries dead space and the gap to the tap point never adapts.

## Change

`_memberBubble` in `lib/ui/map_page.dart`:

- Drop the fixed `SizedBox` height — the card sizes to its content.
- Anchor by **bottom edge** (`Positioned.bottom = mapHeight - tapY + 10`)
  so the bubble sits a constant 10 px above the tap point regardless of
  one or two action buttons; near the top edge (tapY < ~180) it flips to
  anchor by `top` below the tap instead.
- Add a small triangle leader (CustomPaint) whose tip points at the tap
  point; the leader is offset horizontally so the tip lands on the tap x
  even when the card was clamped sideways.
- `_pickMemberAtTap` stores the raw tap offset (`_bubbleAt = offset`);
  the 10 px gap + flip live in the bubble.
- Tap-point clearance is preserved by construction (bubble bottom is
  always ≥10 px above the tap), so the tie-cycling tap behavior and its
  widget test are unchanged.

## Verify

`flutter analyze` clean, `flutter test` passes (existing bubble widget
tests keep passing — keys unchanged). Commit plan + change together.
