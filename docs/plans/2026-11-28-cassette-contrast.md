# Cassette chrome: WCAG contrast tests and tone fixes

Implements: — (follow-up to 265ee20 / d909986: "add testing for contrast
and try to prevent issues for it")

## What

The cassette style's colors currently sit inline in the widgets, with the
scrubber thumb's face/edge **hardcoded** — a measured contrast bug (the
light-theme thumb reads 1.09–1.13:1 against the playback card: invisible),
and the cap borders (outlineVariant, 1.3–1.8:1 vs the cap face) rely on the
drop shadow alone against the map's arbitrary tiles. This slice:

1. **Tone objects** — all cassette colors flow through two small, public
   value objects in `cassette_key.dart`: `CassetteTones.of(scheme)` (raised
   and latched cap gradient stops, border, glyph/caption, LED) and
   `CassetteScrubberTones.of(scheme)` (groove, groove border, played tint,
   thumb face, thumb edge). The widgets consume them; they are the single
   place a future color change can break contrast.
2. **Fixes** (chosen from measured ratios, both app themes, seed 0xFF4363D8):
   - Cap border: `outlineVariant(0.7)` → `scheme.outline` (3.5–5.9:1 vs
     the cap face — the key keeps a ≥3:1 boundary even over tiles matching
     the face tone; the drop shadow stays for imagery).
   - Scrubber thumb: hardcoded `0xFFF0F0EC`/`0xFF8F8F88` →
     `scheme.onSurface` face with `scheme.outline` edge (9.6–13.3:1 vs the
     groove — the light-theme invisibility is gone; reads as the deck's
     dark capstan, matching the approved mockup).
   - Groove: a custom `_GrooveTrackShape` that draws the recessed channel
     with a 1 px `scheme.outline` border (3.5–5.9:1 vs the card), instead
     of the bare `RoundedRectSliderTrackShape` fill (1.2–1.5:1).
3. **Contrast tests** (`test/cassette_contrast_test.dart`) — a WCAG
   relative-luminance/contrast helper plus assertions over the tone
   objects in **both** app themes (light and dark, same seed as main.dart):
   - glyph/caption color vs every raised and latched gradient stop ≥ 4.5
   - cap border vs every stop ≥ 3 (WCAG 1.4.11 component boundary)
   - lit LED vs every stop ≥ 3
   - thumb face and edge vs groove ≥ 3; played tint vs groove ≥ 3;
     groove border vs the card's surface ≥ 3
   The ratios above were measured with this exact method (see the probe
   numbers in the conversation record) — the tests pin them.

Out of scope by nature: contrast against the map's tiles is imagery-
dependent and cannot be tested deterministically; the ≥3:1 border plus
the drop shadow is the mitigation, and the ≥3:1-vs-face test is the
strongest deterministic guarantee available without a scrim (which the
user removed with the deck panel).

## Steps

1. `cassette_key.dart`: add `CassetteTones` / `CassetteScrubberTones`,
   refactor `CassetteKey`, `CassetteScrubber` and `_CapstanThumbShape`
   (takes its colors as constructor fields from the tones) onto them;
   border switch to `outline`; add `_GrooveTrackShape`.
2. `test/cassette_contrast_test.dart`: the WCAG helper + assertions above.
3. Existing cassette tests untouched (they assert structure, not colors);
   `flutter analyze` clean, `flutter test` green, commit.
