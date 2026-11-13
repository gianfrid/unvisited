# Research prompt: offline road matching for a privacy-first track viewer

Copy everything below the line into a research-capable LLM (one that can
search the web and cite sources). The prompt is self-contained.

---

You are a senior mobile-map-engineering consultant. Research and recommend
an approach for **offline road matching** in a specific app. Use web search
for current facts (library versions, data formats, extract sizes, licenses)
and cite sources for every factual claim. Do not propose anything that
violates the constraints; if a popular approach violates one, say so
explicitly and explain what would have to change.

## The app

"Unvisited" is a Flutter app (Android first, desktop Linux for development)
that imports GPS track files (GPX, Garmin FIT, Strava TCX/KMZ) and renders
them as a **fog-of-war exploration overlay** on a single OpenStreetMap map
(flutter_map + raster OSM tiles). Every track point unlocks the area around
it: translucent circles (15 m radius, from a square grid of ~12 m cells
coalesced from points) drawn over the tiles. There is no recording, no
routing, no navigation — it is a viewer of where you have been.

**The feature to research** (already agreed in the spec, implementation
deferred): a section of an OSM road/trail that runs close to unlocked
points is **matched and unlocked with them** — so walking a road unlocks
the corridor of that road, not just disjoint 15 m circles along it.

## Hard constraints (from the spec — treat as fixed unless the research
shows a constraint is genuinely untenable, in which case say what and why)

1. **Privacy / network**: all data is local only. **No network calls beyond
   fetching OSM map tiles** — so no Overpass/OSRM/Valhalla server queries
   at runtime, no cloud, no analytics. Anything road-related must work
   fully offline on device.
2. **No database package**: the catalog is a JSON index by design. Road
   data may be a bundled or user-provided file, but ask before adding any
   pub.dev dependency beyond the established set (flutter_map, latlong2,
   file_picker, xml, archive).
3. **Parsing must be portable Dart** (pure Dart, unit-testable, no Flutter
   imports), kept behind an interface so a future Rust core (Dart FFI)
   can slot in later.
4. Small vertical slices; each ends with tests against checked-in fixtures.
5. App runs on mid-range Android phones; APK size and memory at runtime
   matter. Storage budget for road data should be stated per region size
   (a city, a region, a country, Europe).

## Research questions (answer each, with sources)

1. **Is true map matching even needed?** The goal is "which road segments
   did the user visit", not "snap the GPS trace". Compare:
   (a) pure geometric matching — buffer the unlocked points/circles and
   intersect with road geometry, no Hidden Markov model;
   (b) HMM map matching (Newson & Krumm 2009 style) as used by OSRM
   `/match`, Valhalla's Meili, GraphHopper's map-matching;
   (c) hybrid: geometric candidate lookup + simple continuation scoring.
   For each: what it needs as input (timestamps? heading?), failure modes
   for dense urban canyons, sparse trails, and 1 s vs smart-recorded
   (variable-interval) GPS points, and whether the simpler option
   achieves a visually correct unlocked corridor.

2. **Offline road data sources**: Geofabrik (extract sizes per
   region/country, update cadence, ODbL attribution obligations), other
   OSM extract providers, and what a minimal custom extract pipeline
   (e.g. osmium filtering to a road-only subset) would look like. State
   realistic on-disk sizes for roads-only data: a city, a German region,
   all of Germany, western Europe.

3. **On-device road data format**: how to store/query road geometry
   offline on mobile — plain OSM PBF parsed in Dart (existing Dart PBF
   parsers? quality?), a preprocessed flattened format (polyline
   encoding, custom binary, sqlite-based — note constraint 2), spatially
   indexed tiles (e.g. zoom-cell buckets of segments), or reusing an
   existing engine's format (Valhalla tiles, GraphHopper custom). For
   each: parse cost in Dart, lookup story for "roads near this lat/lon",
   and update path when OSM changes.

4. **Prior art to steal from**: existing open-source map matchers
   (Valhalla Meili, OSRM, GraphHopper map-matching, Barefoot, etc.),
   their language, whether their algorithm has been ported to Dart, and
   what a Dart port of the *simplest adequate* algorithm would involve.
   Also check whether any Flutter/Dart package already does offline road
   matching or PBF parsing.

5. **Rust exit hatch**: given constraint 3, evaluate doing the matching in
   Rust behind FFI from day one vs pure Dart first. What Rust crates
   (geo, s2, rstar, osmpbf…) would give: candidate road lookup + matching;
   what the FFI surface (bytes in, unlocked segment ids out) would look
   like; and the realistic maintenance cost difference for a hobby-scale
   app.

6. **Zoom/UX integration**: unlocked corridors get drawn as translucent
   overlays like the existing circles (fat polylines). Any rendering
   advice for flutter_map (polyline layers vs custom canvas) at country
   scale with thousands of unlocked segments — simplification thresholds
   (Douglas-Peucker), zoom-dependent level of detail.

## Deliverable format

1. **A comparison table** of 3–4 candidate architectures (data source +
   format + algorithm + storage + deps), scored against: spec compliance,
   implementation effort, APK size, runtime memory, match quality,
   maintenance.
2. **A recommendation** with justification, including the smallest viable
   first slice (what it does, what it doesn't, how it is tested) and the
   follow-up slices.
3. **Open questions** that genuinely need the project owner's decision,
   phrased as concrete either/or choices with your default recommendation.
4. **Sources** for every version, size and license claim.
