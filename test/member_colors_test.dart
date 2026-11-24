import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/aggregate/aggregate_tracks.dart';
import 'package:unvisited/aggregate/member_colors.dart';

/// At lat 45, 0.0002 deg of longitude is ~15.7 m (within the 30 m default
/// near threshold) and 0.01 deg of latitude is ~1.1 km (far).
void main() {
  AggregateInput track(String id, List<LatLng> points) =>
      AggregateInput(id: id, points: points);

  test('near tracks never share a color, far tracks may repeat one', () {
    final a = track('a', [const LatLng(45.0, 9.0)]);
    final b = track('b', [const LatLng(45.0, 9.0002)]); // ~15.7 m from a
    final c = track('c', [const LatLng(45.01, 9.0)]); // ~1.1 km from both
    final palette = const ['p1', 'p2', 'p3'];

    final colors = assignMemberTintKeys([a, b, c], palette: palette);

    expect(colors[a.id] == colors[b.id], isFalse,
        reason: 'a and b are near, so they must differ');
    expect(colors.values.every(palette.contains), isTrue,
        reason: 'only palette keys are used');
    // c is near nobody, so greedy gives it the first free palette key —
    // the same one a (first in degree/id order) took.
    expect(colors[c.id], colors[a.id]);
  });

  test('the assignment is deterministic under input order', () {
    final a = track('a', [const LatLng(45.0, 9.0)]);
    final b = track('b', [const LatLng(45.0, 9.0002)]);
    // ~23.6 m from a and ~7.9 m from b: all three pairwise within 30 m.
    final c = track('c', [const LatLng(45.0, 9.0003)]);
    final palette = const ['p1', 'p2', 'p3', 'p4'];

    final forward = assignMemberTintKeys([a, b, c], palette: palette);
    final reversed = assignMemberTintKeys([c, b, a], palette: palette);

    expect(reversed, forward);
    // A three-track clique is fully colored with distinct keys while the
    // palette lasts.
    expect(forward.values.toSet(), hasLength(3));
  });

  test('past the palette size, repetitions are forced but palette-bound', () {
    // Four tracks all within 30 m of each other (a clique), two colors.
    final members = [
      for (var i = 0; i < 4; i++)
        track('t$i', [LatLng(45.0, 9.0 + i * 0.0001)]),
    ];
    final colors =
        assignMemberTintKeys(members, palette: const ['x', 'y']);
    expect(colors.values.toSet(), {'x', 'y'});
    expect(colors.length, 4);
  });

  test('empty member list maps to empty, empty palette throws', () {
    expect(assignMemberTintKeys(const [], palette: const ['x']), isEmpty);
    expect(() => assignMemberTintKeys(
        [track('a', [const LatLng(45.0, 9.0)])], palette: const []),
        throwsArgumentError);
  });
}
