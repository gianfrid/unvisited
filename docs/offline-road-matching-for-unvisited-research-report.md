# Offline Road Matching for Unvisited — Research Report

**Question.** How should the Unvisited app (Flutter, offline-only, fog-of-war viewer over raster OSM tiles) implement "walking a road unlocks the corridor of that road"? Which road-data source, on-device format, and matching algorithm satisfy the spec constraints (no runtime network beyond map tiles, no database package, portable Dart parsing behind an interface, small APK, mid-range Android targets)?

**Date of research:** 2026-11-13. Sizes and versions are current as of this date.

## Executive Summary

1. **True HMM map matching is not needed for v1.** The goal is "which road segments did the user visit", not "reconstruct the exact driven route". A geometric point-to-segment buffer match (distance from unlocked points to road polylines, with a per-way vote threshold and an optional cheap continuity tiebreak) achieves a visually correct unlocked corridor at a fraction of the complexity. HMM (Newson & Krumm 2009) earns its keep when traces are sparse (30 s+ sampling) or when wrong-road picks must be impossible; it needs a routable graph, which drags in GraphHopper/Valhalla/OSRM-scale machinery. The Newson & Krumm paper itself documents degradation as sampling intervals grow, but the paper's failure mode (breaking at 30 s sampling) is exactly the case Unvisited largely avoids by using the point cloud, not the trace. ([Microsoft Research](https://www.microsoft.com/en-us/research/publication/hidden-markov-map-matching-noise-sparseness/))
2. **The preprocessed-format route dominates plain PBF on-device.** Parse Geofabrik PBF offline (osmium tags-filter to `w/highway` + `--used-node`), then flatten to a compact custom binary or JSON-per-bucket format with a fixed zoom-cell spatial index. Two Dart PBF readers exist (`dart_osmpbf`, `osm.dart`), but both are young/low-adoption; a desktop-only PBF parse avoids shipping a PBF parser in the APK at all. ([osmium manual](https://osmcode.org/osmium-tool/manual.html), [dart_osmpbf](https://pub.dev/documentation/dart_osmpbf/latest/), [osm.dart](https://github.com/robert-ancell/osm.dart))
3. **Roads-only storage is small.** Berlin's full extract is 95 MB PBF; Germany is 4.5 GB and Europe 33 GB for all OSM data, but the highway subset is a small fraction: a flattened, indexed roads-only file realistically lands at ~5–15 MB for a city, ~100–300 MB for a German region or all of Germany, and ~1 GB-scale for western Europe (estimates; see Findings 2 for derivation). ([Geofabrik Berlin](https://download.geofabrik.de/europe/germany/berlin.html), [Geofabrik Germany](https://download.geofabrik.de/europe/germany.html), [Geofabrik Europe](https://download.geofabrik.de/europe.html))
4. **Go pure Dart first, Rust later.** Constraint 3 already demands an interface; matching ~10³–10⁴ points against bucket-loaded segments is milliseconds-to-seconds work in Dart. The Rust exit hatch (rstar R*-tree + geo crates, osmpbf for a Rust-side importer, flutter_rust_bridge for bindings) stays open and is well-trodden. Doing Rust from day one roughly doubles the build/toolchain surface for a hobby-scale app for no user-visible gain in slice 1. ([rstar](https://crates.io/crates/rstar), [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge))
5. **Rendering: reuse flutter_map's PolylineLayer, rely on its built-in culling and simplification, and do zoom-dependent LOD yourself.** flutter_map already culls off-screen polylines and applies Douglas-Peucker-style simplification with a configurable tolerance; the official docs recommend zoom-dependent simplification for large sets. ([flutter_map docs](https://docs.fleaflet.dev/layers/polyline-layer), [flutter_map v6 docs](https://docs.fleaflet.dev/v6/layers/polyline-layer))
6. **Prior art exists but none is portable to Dart for free.** Valhalla Meili, OSRM `/match`, GraphHopper map-matching, and Barefoot all implement Newson & Krumm-style HMM on top of a routing graph in C++/Java; none has a Dart port, and no Flutter/Dart package does offline road matching. Wandrer and CityStrides prove the product concept (GPS-trace-to-OSM-road coverage) but are server-side. ([Valhalla Meili](https://valhalla.github.io/valhalla/contributing/architecture/meili/), [GraphHopper map-matching](https://github.com/graphhopper/graphhopper/tree/master/map-matching), [Barefoot](https://github.com/bmwcarit/barefoot), [Apps for Strava](https://appsforstrava.com/blog/strava-exploration-apps))
7. **ODbL compliance is just attribution for this use case.** A roads-only extract flattened into the app's own format is a Produced Work (or at worst a Derivative Database kept private); public display requires a reasonable "© OpenStreetMap contributors" notice, which the app already shows for tiles. ([OSMF attribution guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines))

## Methodology

Search angles: the HMM map-matching literature (Newson & Krumm 2009 as ground truth), the algorithm docs of Valhalla Meili / GraphHopper / Barefoot, Geofabrik download pages for current extract sizes and update cadence, osmium-tool documentation for the extraction pipeline, pub.dev for Dart PBF parsers and protobuf support, GeoRust for the Rust exit-hatch crates, flutter_map docs for rendering performance. All sizes were read from the live Geofabrik download pages (November 2026). Roads-only derived sizes are estimates computed from the extract sizes and typical highway-subset ratios; they are labeled as estimates throughout. Limitation: no source states a canonical "roads-only PBF" size per region; the numbers in Findings 2 are reasoned estimates, and slice 1 includes a step to measure them exactly.

## Findings

### 1. Is true map matching even needed?

**What each approach is.**

(a) **Pure geometric matching.** For each unlocked cell/point (already on a ~12 m grid), find road segments within a threshold (≈15–20 m, matching the circle radius) using a spatial index, compute point-to-segment distance, and mark the segment "visited" when enough of its length or enough distinct points fall inside the corridor. No timestamps, no headings, no graph. The Newson & Krumm paper notes purely geometric approaches exist but are "sensitive to measurement noise and sampling rate"; that sensitivity matters for reconstructing a single correct route, much less for deciding *whether* a road was touched. ([paper PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/map-matching-ACM-GIS-camera-ready.pdf))

(b) **HMM map matching.** Newson & Krumm model each GPS point as an observation, candidate road positions as hidden states, and use emission probabilities (point-to-road distance, Gaussian around expected GPS noise) plus transition probabilities (route distance between candidates vs. great-circle distance) to find the most likely road sequence via Viterbi. This is what Valhalla's Meili implements (Viterbi with a routing-cost transition model), what GraphHopper's map-matching implements (candidates + routing distances between consecutive candidates), and what Barefoot implements standalone in Java. All three need a *routable graph*, not just geometry, because transition costs are shortest-path distances. ([Meili architecture](https://valhalla.github.io/valhalla/contributing/architecture/meili/), [Meili algorithms](https://valhalla.github.io/valhalla/contributing/architecture/meili/algorithms/), [GraphHopper map-matching](https://github.com/graphhopper/graphhopper/tree/master/map-matching), [Barefoot wiki](https://github.com/bmwcarit/barefoot/wiki))

(c) **Hybrid.** Geometric candidate lookup (same index as (a)) plus a light continuity score: prefer a segment already active from the previous cluster of points, penalize segment hopping when consecutive points are close together. This is a degenerate one-step HMM — no routing graph, no timestamps needed, ~50–100 lines of Dart.

**Failure modes compared.**

| Scenario | Geometric (a) | HMM (b) | Hybrid (c) |
|---|---|---|---|
| Dense urban canyon, parallel roads <15 m apart (service road beside a main road) | Over-unlocks: both segments light up | Picks one, sometimes the wrong one | Mild over-unlock |
| Sparse trails, single path in woods | Correct (only nearby geometry exists) | Correct, but overkill | Correct |
| 1 s recording | Correct | Correct | Correct |
| Smart recording (variable interval, Garmin pause events) | Correct: works on the point cloud; gaps simply unlock less corridor | Degrades as intervals grow — the original paper's headline result is the algorithm's accuracy breaking down with reduced sampling rate | Correct, mildly better than (a) across gaps |
| Standing still / GPS jitter around an intersection | Unlocks the intersection area only | May lock onto one arbitrary arm | Unlocks the intersection area |

**Verdict.** For a fog-of-war *coverage* overlay, false-positive unlocking of a parallel service road is a cosmetic issue the existing 15 m circles already cause (a parked-adjacent-to-road point unlocks the road's corridor today, geometrically). HMM's advantage — a single consistent route — buys nothing visually here, and it disqualifies itself on constraints: it needs a routable graph (Valhalla .gph tiles, GraphHopper .ghz — both opaque, build-pipeline-heavy formats), and none of the engines runs in Dart. The simpler option (a), upgraded to (c) if quality demands it, achieves a visually correct corridor. Geometric matching also composes naturally with the existing cell grid: the unlocked-cells set *is* the query input, so matching is idempotent and incremental per imported track.

### 2. Offline road data sources

**Geofabrik** is the default source: free extracts per continent/country/region, updated daily (region pages show "last modified" within ~24 h of research date), with `.osc.gz` change files available for incremental updates, and a documented ODbL attribution obligation. Current full-extract sizes: Berlin 95 MB, Nordrhein-Westfalen (a German region) 871 MB, Germany 4.5 GB, DACH 5.8 GB, Europe 33.0 GB, planet 89.1 GB PBF. ([Berlin](https://download.geofabrik.de/europe/germany/berlin.html), [NRW](https://download.geofabrik.de/europe/germany/nordrhein-westfalen.html), [Germany](https://download.geofabrik.de/europe/germany.html), [DACH](https://download.geofabrik.de/europe/dach.html), [Europe](https://download.geofabrik.de/europe.html), [planet.osm.org](https://planet.osm.org/), [Planet wiki](https://wiki.openstreetmap.org/wiki/Planet.osm))

**Custom extract pipeline.** One osmium command filters to roads with way references: `osmium tags-filter region.osm.pbf w/highway -o roads.osm.pbf` (the manual's own example filters Roman highways this way; OpenTripPlanner's documented pipeline uses exactly this pattern for routable networks, and Stack Overflow/community guidance confirms keeping only the `highway` key). Optionally exclude `highway=proposed/construction/elevator`, and restrict to the region with `osmium extract -b/-p` first. ([osmium manual](https://osmcode.org/osmium-tool/manual.html), [OTP docs](https://docs.opentripplanner.org/en/v2.2.0/Preparing-OSM/))

**Realistic roads-only on-disk sizes (estimates).** Buildings dominate OSM volume; the highway subset is typically ~5–10% of nodes/ways and less of the byte volume (way geometry + a handful of tags). Applying that to the measured extract sizes plus format overhead:

| Region | Geofabrik full PBF | Roads-only flattened, indexed |
|---|---|---|
| City (Berlin) | 95 MB | **38 MB (measured, slice 5)** |
| German region (NRW) | 871 MB | ~300–400 MB (scaled from the Berlin measurement; not measured) |
| Germany | 4.5 GB | ~1.5–2 GB (scaled; not measured) |
| Western Europe | ~20–25 GB (share of 33 GB Europe file) | ~6–8 GB (scaled; not measured) |
| Europe | 33 GB | ~9–12 GB (scaled; not measured) |

Measured on the real November 2026 Berlin extract (95 MB, unfiltered — the build tool drops non-highway ways itself): 1,342,290 ways scanned in 4.3 s, 475,130 highway ways kept, output 38 MB in 46 z12 buckets (~80 B/way incl. bucket duplication). That is 2.5–8× the original 5–15 MB estimate — the JSON bucket payloads and per-bucket duplication dominate — which strengthens the case for the binary-layout follow-up in the profiling TODO before Germany-sized regions. Opening is cost-free by design (directory only, ~9 ms), and parsing a 3×3 bucket neighborhood in central Berlin (272 k ways) takes ~330 ms cold on the desktop VM — a walk touches a few buckets once, and per-bucket work amortizes thereafter.

**Licensing.** Geofabrik extracts are ODbL. Unvisited's flattened roads file is a Derived/Produced Work; public display requires attribution "reasonably calculated to make any Person … aware that Content was obtained from OpenStreetMap". The app already attributes OSM for tiles; the same notice covers the road data. Note Geofabrik strips user names/IDs/changeset IDs from extracts for GDPR reasons, which also simplifies compliance on the app side. ([attribution guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines), [community advice](https://wiki.openstreetmap.org/wiki/Community_attribution_advice), [Geofabrik main](https://download.geofabrik.de/))

### 3. On-device road data format

**Option A — parse plain OSM PBF in Dart.** Two Dart readers exist: `dart_osmpbf` (MIT, depends on archive/fixnum/protobuf, low adoption: ~40 downloads, 130 pub points, loads whole file into memory via `OsmData.fromBytes`) and `osm.dart` (streams elements, reports 434 MB New Zealand extract scanned in 25 s end-to-end with tag filtering at 1.7 s). Both are hobby-grade; `dart_osmpbf`'s whole-file-in-memory model is a non-starter for region-scale data on mid-range Android. PBF parsing also violates the spirit of constraint 2 unless `protobuf` + a reader package are accepted as new dependencies. Verdict: viable only as a *desktop-side* import path, or if a streaming reader is written in-house. ([dart_osmpbf](https://pub.dev/documentation/dart_osmpbf/latest/), [dart_osmpbf versions](https://pub.dev/packages/dart_osmpbf/versions), [osm.dart](https://github.com/robert-ancell/osm.dart), [protobuf package](https://pub.dev/packages/protobuf))

**Option B — preprocessed flattened format (recommended).** A build step (Dart CLI or Rust CLI, run on the Linux dev machine) turns `roads.osm.pbf` into the app format:

- Geometry: per-way polyline, coordinates as delta-encoded varint (Google/Mapbox encoded-polyline algorithm: lossy at ~1.1 m at the equator with 5 decimal digits — finer than consumer GPS and finer than the 12 m cell grid, so acceptable; 6-digit precision available if ever needed). ([Google polyline spec](https://developers.google.com/maps/documentation/utilities/polylinealgorithm), [polyline precision analysis](https://diragb.dev/blog/polyline-algorithm/))
- Index: fixed zoom-cell buckets (e.g. web-mercator tiles at z10–z12); each bucket lists segment ids whose geometry intersects it, plus a way-id → (class, name, geometry offset) table in a JSON sidecar, honoring the "catalog is a JSON index" design.
- Lookup: "roads near this lat/lon" = open one bucket file (mmap or read-through cache), test the point against each segment's bbox then exact point-to-segment distance. Bounded memory: only buckets covering the unlocked area are loaded.
- Update path: re-run the build script against a fresh Geofabrik extract; because unlocked state is stored as *way ids + matched length ratio* (not segment copies), old unlock state survives OSM edits as long as way ids persist. (OSM way ids are stable across edits; re-splits invalidate individual ways — accept minor unlock loss or keep a way-id → old-id migration note.)

Parse cost in Dart: decoding varint polylines and a bucket header is trivial, pure Dart, unit-testable with checked-in fixtures — satisfying constraints 3 and 4 directly.

**Option C — sqlite/spatialite.** Explicitly excluded by constraint 2 (no database package).

**Option D — reuse an engine format (Valhalla .gph tiles, GraphHopper).** Valhalla tiles are binary graph tiles on a 3-level lat/lon grid with no standalone format spec — the C++ headers *are* the definition — built by a heavy toolchain (valhalla_build_tiles, admins, timezones); GraphHopper similarly requires its own import and warns that edge/node ids change per PBF build. These formats bundle routing data (speeds, costs, turn restrictions) that Unvisited doesn't need, at a size cost. Reusing them would couple the app to C++ tooling and an undocumented binary layout. Verdict: rejected unless the HMM route is later chosen, and even then only behind the interface. ([valhalla_gph](https://github.com/bertt/valhalla_gph), [Valhalla getting started](https://valhalla.github.io/valhalla/mjolnir/getting_started_guide/), [GraphHopper map-matching](https://github.com/graphhopper/graphhopper/tree/master/map-matching))

### 4. Prior art to steal from

- **Valhalla Meili** — C++ library, HMM per Newson & Krumm, Viterbi over candidates with routing-based transition costs; needs Valhalla tiles. The algorithm docs are clear enough to reimplement. ([Meili](https://valhalla.github.io/valhalla/contributing/architecture/meili/), [algorithms](https://valhalla.github.io/valhalla/contributing/architecture/meili/algorithms/))
- **OSRM `/match`** — C++ HMM matcher tied to OSRM's data model; same story.
- **GraphHopper map-matching** — Java, in the main repo; "distances between GPS positions and map matching candidates as well as the routing distances between consecutive map matching candidates are taken into account"; usable offline via CLI; needs a GraphHopper import. ([repo](https://github.com/graphhopper/graphhopper/tree/master/map-matching), [README](https://github.com/graphhopper/graphhopper/blob/master/map-matching/README.md))
- **Barefoot (bmwcarit)** — standalone Java HMM matcher, Apache 2.0, offline and online modes; the *simplest adequate* reference implementation to read. A Dart port of Barefoot-minus-routing (candidate emission + Viterbi over segment continuity) is the natural upgrade path from hybrid (c). ([GitHub](https://github.com/bmwcarit/barefoot), [release post](http://www.bmw-carit.com/blog/barefoot-release-an-open-source-java-library-for-map-matching-with-openstreetmap/))
- **Dart/Flutter packages.** No pub.dev package does offline road matching; no Dart port of any of the above exists. The only relevant Dart libraries are the two PBF readers above. Conclusion: any matcher is in-house code; the field is geometry + a few hundred lines.

### 5. Rust exit hatch

**Crates.** GeoRust's `geo` (geometry + algorithms; uses `rstar` internally as spatial index), `rstar` (R*-tree, nearest-neighbor and envelope queries, Apache-2.0, actively maintained), and `osmpbf` (zero-copy PBF reading) cover the whole pipeline: import PBF → build R*-tree → match points → emit visited way ids. `flutter_rust_bridge` (v2, feature-rich, generates type-safe Dart bindings) is the established bridge; the knowledge base already records Dart FFI + flutter_rust_bridge as the lowest-friction Rust-reuse path for this project. ([rstar](https://crates.io/crates/rstar), [GeoRust](https://georust.org/), [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge), [frb on pub.dev](https://pub.dev/packages/flutter_rust_bridge))

**FFI surface.** Keep it byte-oriented and versioned: `init(reader: road-file path or bytes)`, `match(track: serialized points/cells) -> list of (way_id, matched_length_ratio)`. Bytes in, unlocked segment ids out — exactly the shape the spec's interface anticipates, and identical to the Dart interface so the swap is invisible above the boundary.

**Pure Dart first vs Rust from day one.** Realistic maintenance cost difference for a hobby-scale app: Rust-first adds a second toolchain, cross-compilation targets (Android NDK + Linux), generated bindings, and dual test harnesses — call it a 1.5–2× engineering-time multiplier on every matching change — in exchange for speed the workload doesn't need (a city file's relevant buckets hold thousands of segments; a walk touches hundreds of points; Dart does this interactively). The performance cliff only arrives at country-scale whole-planet matching or HMM-over-routing-graphs. Recommendation: pure Dart slice 1–3 behind the byte-oriented interface; move to Rust only if measurement shows matching paining import time on mid-range hardware, and then port the *same* interface with flutter_rust_bridge.

### 6. Zoom / UX integration

- Reuse `PolylineLayer` with fat translucent strokes (stroke width in screen pixels via ` strokeWidth`), matching the circle overlay's visual language. flutter_map performs built-in culling of off-screen polylines — a property even the Flutter team's google_maps_flutter tracker acknowledges as flutter_map's advantage for large polyline sets — and applies simplification (Douglas-Peucker-style) with a configurable `simplificationTolerance` (default 0.4) that must run before culling. ([flutter_map docs](https://docs.fleaflet.dev/layers/polyline-layer), [flutter issue](https://github.com/flutter/flutter/issues/105048))
- Official docs explicitly recommend varying simplification with zoom for large sets; implement LOD by precomputing 2–3 simplified variants per segment (e.g. tolerances ~1 m / 10 m / 50 m) at build time and picking per zoom band, so nothing is simplified on the UI thread. ([v6 docs](https://docs.fleaflet.dev/v6/layers/polyline-layer))
- Community benchmarks put flutter_map usable into the tens of thousands of markers/polylines (a 2026 Reddit benchmark reports ~20k markers at 20–30 fps, degrading with heavy geometry); with culling + LOD, country-scale thousands of unlocked segments are feasible; if it ever isn't, merge visited ways per bucket into single merged MultiPolyline objects to cut path count. ([Reddit benchmark](https://www.reddit.com/r/FlutterDev/comments/1i2ldzn/thoughts_on_google_maps_flutter_vs_flutter_map/))
- Known pitfall: `saveLayer`/opacity in custom painters is expensive; prefer stroke color with alpha over per-polyline opacity widgets, and avoid animating the polyline list every frame (a 2.x-era lag report specifically fingered opacity/saveLayer cost). ([flutter_map issue #1217](https://github.com/fleaflet/flutter_map/issues/1217))

## Comparison of Candidate Architectures

Scores: 1 (poor) – 5 (excellent). "Deps" counts additions beyond the established set.

| Criterion | **A. PBF-in-app + geometric match** | **B. Preprocessed flat format + geometric/hybrid match (pure Dart)** | **C. Preprocessed flat format + hybrid match in Rust (FFI from day 1)** | **D. Valhalla/GraphHopper tiles + HMM** |
|---|---|---|---|---|
| Spec compliance | 2 — needs `protobuf` + PBF dep, whole-file memory risks | **5** — no new runtime deps, JSON index preserved | 4 — no pub deps but adds Rust toolchain/FFI surface | 1 — violates network/db/portability spirit; engine formats opaque |
| Implementation effort | 3 | **4** | 2 | 1 |
| APK size | 3 — PBF parsing code + raw-ish data, city bundle ~50–100 MB | **4** — city bundle 5–15 MB; app code tiny | 4 — same data, small .so | 2 — engine tile imports heavy |
| Runtime memory | 2 — unbounded without streaming | **5** — bucket-loaded, tens of MB | 5 | 2 — graph caches sized for routing |
| Match quality (visual corridor) | 4 | 4 (5 with hybrid scoring) | 5 | 5 (but quality overkill; wrong-road risk exists too) |
| Maintenance | 2 — pinned to hobby-grade PBF lib | **5** | 3 | 1 — foreign binary formats, engine upgrades |
| **Total** | 16 | **27–28** | 23 | 12 |

## Recommendation

**Adopt architecture B: osmium-filtered Geofabrik extract → offline build step → flattened varint-polyline buckets + JSON index → pure Dart geometric matcher behind a byte-oriented interface → flutter_map PolylineLayer with precomputed LOD.** It is the only candidate scoring full spec compliance, and every score it loses to C (match quality ceiling, raw speed) is a margin the product does not consume. The Rust hatch stays open because the interface is defined in serialized terms, not Dart objects.

**Smallest viable first slice.** "Match a GPX against a bundled city road file and unlock way ids."

- Input: one checked-in city extract (e.g. Berlin), preprocessed by a desktop Dart CLI (`osmium tags-filter` upstream) into the bucket format; a checked-in GPX fixture with a known walk along 2–3 streets.
- Deliverable: a pure-Dart `RoadMatcher` interface + geometric implementation that takes (points/cells, road store) and returns visited way ids with matched-length ratios; unit tests against the fixture assert exactly which ways unlock and which parallel ones don't.
- What it does not do: no UI change, no hybrid scoring, no user-provided region files, no incremental OSM updates, no Rust.

**Follow-up slices.**

2. Render unlocked corridors as translucent polylines over the tile layer, merged with circle unlocking in one overlay; visual fixture tests at two zoom levels.
3. Hybrid continuation scoring (candidate preference for the previously active way); fixture with a road beside a service road.
4. Region file side-loading (user picks a file; same parser); JSON catalog entry per region; measured sizes replace the estimates above.
5. LOD/simplification variants at build time; perf test on mid-range Android profile with 5k+ unlocked segments.
6. (Optional) Rust core behind the same interface if measurements demand; port matcher 1:1 with flutter_rust_bridge.

## Open Questions (owner decisions)

1. **Road classes in scope:** all `highway=*` including footway/path/track, or motor-vehicle roads only? Default: all classes — the app tracks walking as much as driving, and excluding footways would make walking corridors unmatchable.
2. **Unlock threshold:** a way unlocks at first touched segment, at ≥50% of length within point corridors, or per-segment (unlock only the sub-linestring actually walked)? Default: per-segment at the existing ~15 m radius, with a way flagged "complete" at ≥90% — matches the corridor visual without implying full traversal.
3. **Region distribution:** bundle one city in the APK and require side-loading for more, or ship an empty APK and make every region user-provided? Default: bundle nothing initially (keep APK small and region-agnostic), add a bundled home-region file later if onboarding friction shows up.
4. **Desktop PBF parsing dependency:** accept `protobuf` + `dart_osmpbf`/`osm.dart` as dev-side-only dependencies for the build CLI (constraint 2 asks before adding any pub.dev dependency — even dev deps), or hand-write the tiny PBF read path? Default: accept them as dev_dependencies only; if either proves unstable, a minimal streaming PBF reader in the build CLI is a bounded, well-specified task.

## Source Notes

| Source | Credibility | Last updated |
|---|---|---|
| [Hidden Markov Map Matching Through Noise and Sparseness — Microsoft Research](https://www.microsoft.com/en-us/research/publication/hidden-markov-map-matching-noise-sparseness/) | 5/5 | 2009 |
| [Newson & Krumm paper PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/map-matching-ACM-GIS-camera-ready.pdf) | 5/5 | 2009 |
| [Valhalla Meili architecture](https://valhalla.github.io/valhalla/contributing/architecture/meili/) | 5/5 | - |
| [Valhalla Meili algorithms](https://valhalla.github.io/valhalla/contributing/architecture/meili/algorithms/) | 5/5 | - |
| [Valhalla .gph tile format exploration](https://github.com/bertt/valhalla_gph) | 3/5 | - |
| [Valhalla Mjolnir getting started](https://valhalla.github.io/valhalla/mjolnir/getting_started_guide/) | 5/5 | - |
| [GraphHopper map-matching (repo)](https://github.com/graphhopper/graphhopper/tree/master/map-matching) | 5/5 | - |
| [GraphHopper map-matching README](https://github.com/graphhopper/graphhopper/blob/master/map-matching/README.md) | 5/5 | - |
| [Barefoot on GitHub](https://github.com/bmwcarit/barefoot) | 5/5 | - |
| [Barefoot wiki](https://github.com/bmwcarit/barefoot/wiki) | 4/5 | - |
| [Barefoot release post](http://www.bmw-carit.com/blog/barefoot-release-an-open-source-java-library-for-map-matching-with-openstreetmap/) | 4/5 | 2015 |
| [Geofabrik Berlin](https://download.geofabrik.de/europe/germany/berlin.html) | 5/5 | 2026-11 |
| [Geofabrik Nordrhein-Westfalen](https://download.geofabrik.de/europe/germany/nordrhein-westfalen.html) | 5/5 | 2026-11 |
| [Geofabrik Germany](https://download.geofabrik.de/europe/germany.html) | 5/5 | 2026-11 |
| [Geofabrik DACH](https://download.geofabrik.de/europe/dach.html) | 5/5 | 2026-11 |
| [Geofabrik Europe](https://download.geofabrik.de/europe.html) | 5/5 | 2026-11 |
| [Geofabrik main download page](https://download.geofabrik.de/) | 5/5 | 2026-11 |
| [planet.osm.org](https://planet.osm.org/) | 5/5 | 2026-11 |
| [Planet.osm wiki (size detail)](https://wiki.openstreetmap.org/wiki/Planet.osm) | 4/5 | 2026-11 |
| [Osmium tool manual](https://osmcode.org/osmium-tool/manual.html) | 5/5 | - |
| [OpenTripPlanner: Preparing OSM Data](https://docs.opentripplanner.org/en/v2.2.0/Preparing-OSM/) | 4/5 | - |
| [dart_osmpbf API docs](https://pub.dev/documentation/dart_osmpbf/latest/) | 3/5 | - |
| [dart_osmpbf versions/adoption](https://pub.dev/packages/dart_osmpbf/versions) | 3/5 | - |
| [osm.dart on GitHub](https://github.com/robert-ancell/osm.dart) | 3/5 | - |
| [protobuf Dart package](https://pub.dev/packages/protobuf) | 4/5 | - |
| [rstar crate](https://crates.io/crates/rstar) | 5/5 | 2026-11 |
| [GeoRust](https://georust.org/) | 4/5 | 2026-11 |
| [flutter_rust_bridge on GitHub](https://github.com/fzyzcjy/flutter_rust_bridge) | 4/5 | - |
| [flutter_rust_bridge on pub.dev](https://pub.dev/packages/flutter_rust_bridge) | 4/5 | - |
| [flutter_map Polyline Layer docs](https://docs.fleaflet.dev/layers/polyline-layer) | 5/5 | - |
| [flutter_map v6 Polyline docs](https://docs.fleaflet.dev/v6/layers/polyline-layer) | 4/5 | - |
| [flutter/flutter #105048 (flutter_map culling comparison)](https://github.com/flutter/flutter/issues/105048) | 3/5 | 2022 |
| [flutter_map #1217 (polyline lag)](https://github.com/fleaflet/flutter_map/issues/1217) | 3/5 | 2022 |
| [Reddit: flutter_map large-dataset benchmark](https://www.reddit.com/r/FlutterDev/comments/1i2ldzn/thoughts_on_google_maps_flutter_vs_flutter_map/) | 2/5 | 2026 |
| [Google Encoded Polyline Algorithm](https://developers.google.com/maps/documentation/utilities/polylinealgorithm) | 5/5 | - |
| [Polyline algorithm precision analysis](https://diragb.dev/blog/polyline-algorithm/) | 3/5 | - |
| [OSMF Licence/Attribution Guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines) | 5/5 | - |
| [OSM wiki: Community attribution advice](https://wiki.openstreetmap.org/wiki/Community_attribution_advice) | 4/5 | - |
| [OSMF Licence and Legal FAQ](https://osmfoundation.org/wiki/Licence/Licence_and_Legal_FAQ) | 5/5 | - |
| [Apps for Strava: exploration apps (Wandrer/CityStrides)](https://appsforstrava.com/blog/strava-exploration-apps) | 3/5 | 2026 |

Caveats: roads-only sizes in Findings 2 are reasoned estimates from measured full-extract sizes, not published figures; the Reddit benchmark is anecdotal (single user, unverified rig); Geofabrik sizes change daily. Valhalla/GraphHopper/OSRM internals were assessed from official docs, not from running the engines.