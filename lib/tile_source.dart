/// OSM raster tile source configuration, shared by the map and tests.
///
/// Official OpenStreetMap tile servers are free but shared infrastructure:
/// the tile usage policy (https://operations.osmfoundation.org/policies/tiles/)
/// requires an application-identifying User-Agent, low volumes and polite
/// caching - all of which this app does.
const tileUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Identifies this app to tile servers, as required by the OSM tile
/// usage policy.
const tileUserAgent = 'unvisited (dev.unvisited.app)';

/// Substitutes `{z}`, `{x}` and `{y}` in [tileUrlTemplate].
String tileUrl(int z, int x, int y) => tileUrlTemplate
    .replaceAll('{z}', '$z')
    .replaceAll('{x}', '$x')
    .replaceAll('{y}', '$y');
