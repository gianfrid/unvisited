/// OSM raster tile source configuration, shared by the map and tests.
///
/// Official OpenStreetMap tile servers are free but shared infrastructure:
/// the tile usage policy (https://operations.osmfoundation.org/policies/tiles/)
/// requires an application-identifying User-Agent, low volumes and polite
/// caching - all of which this app does.
library;

/// The base tile style: standard OSM raster.
const tileUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// The cycle tile style: CyclOSM (https://www.cyclosm.org/), an OSM-based
/// cycle map rendered and hosted by OpenStreetMap France — no API key, the
/// same identifying User-Agent, attribution "CyclOSM | OpenStreetMap
/// contributors", non-commercial use per their policy.
const cycleTileUrlTemplate =
    'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png';

/// Host rotation for [cycleTileUrlTemplate]'s `{s}` placeholder.
const cycleTileSubdomains = ['a', 'b', 'c'];

/// Layer ids as stored in the settings: 'standard' or 'cycle'.
const tileLayerIds = ['standard', 'cycle'];

/// Attribution text per layer id.
String tileAttribution(String layer) => layer == 'cycle'
    ? 'CyclOSM | OpenStreetMap contributors'
    : 'OpenStreetMap contributors';

/// The tile URL template for a settings layer id.
String tileUrlTemplateFor(String layer) =>
    layer == 'cycle' ? cycleTileUrlTemplate : tileUrlTemplate;

/// Identifies this app to tile servers, as required by the OSM tile
/// usage policy.
const tileUserAgent = 'unvisited (dev.unvisited.app)';

/// Substitutes `{z}`, `{x}` and `{y}` in [tileUrlTemplate].
String tileUrl(int z, int x, int y) => tileUrlTemplate
    .replaceAll('{z}', '$z')
    .replaceAll('{x}', '$x')
    .replaceAll('{y}', '$y');

/// Substitutes `{z}`, `{x}`, `{y}` and `{s}` in [cycleTileUrlTemplate]
/// (tests pick a concrete subdomain).
String cycleTileUrl(int z, int x, int y, [String subdomain = 'a']) =>
    cycleTileUrlTemplate
        .replaceAll('{s}', subdomain)
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');
