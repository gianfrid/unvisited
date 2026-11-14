# Slice 9 — drop the local-only claim from the Settings About card

## Context

`aboutDescription` reads "Local-only track recording and exploration on
OpenStreetMap" (en) / "Registrazione ed esplorazione di tracce solo in
locale su OpenStreetMap" (it). Map tiles are fetched from the OSM tile
service, so local-only is false. What is true: imports, the JSON index
and recordings are stored on-device; only the tile fetch uses the
network. No test asserts the exact text (only the strings-coverage
enumeration), so the change is two string literals.

## Steps

1. `lib/l10n/app_strings.dart`, English:
   `aboutDescription` → "Track recording and exploration on OpenStreetMap
   (GPX, FIT, KMZ and TCX). Imports and recordings stay on your device;
   only the map tiles are fetched."
2. Italian: "Registrazione ed esplorazione di tracce su OpenStreetMap
   (GPX, FIT, KMZ e TCX). Importazioni e registrazioni restano sul tuo
   dispositivo; solo i riquadri della mappa vengono scaricati."
3. The strings-coverage test needs no change (getter still exists and is
   enumerated); no other tests reference the text.

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and deletes the slice 9 TODO entry; PLAN.md
  carries over to the next task unmodified.
