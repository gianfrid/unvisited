# Playback: one cassette key for play/pause

Implements: — (follow-up to d909986: "also in playback mode I want a
single button for play/pause")

## What

In the cassette style the replay bar currently renders separate PLAY and
PAUSE keys (plus EJECT). Merge to the flat style's interaction: **one**
transport key that mirrors the merged record key's pattern —

- playing: latched down, pause glyph, caption Pause; tap pauses
- paused/finished: raised, play (replay when finished) glyph, caption
  Play/Replay; tap plays and re-arms the follow camera

EJECT (close) is unchanged. The standard style is already a single
IconButton — untouched.

## Steps

1. `lib/ui/playback_dashboard.dart`: the cassette branch renders one
   `CassetteKey` (key `playback-play`) with `latched: playing`, the
   glyph/caption/tooltip the flat toggle uses, and the flat toggle's
   play/pause dispatch (play re-arms the follow-camera). The separate
   PAUSE key is deleted.
2. `docs/mockups/cassette-buttons.html`: the replay deck mock shows the
   single latched key.
3. `test/cassette_style_test.dart`: a cassette-mode replay test — the
   key rides raised with the play glyph before playing, latches with the
   pause glyph once playing, returns raised after pause; EJECT stays.
4. `flutter analyze` clean, `flutter test` green, commit.
