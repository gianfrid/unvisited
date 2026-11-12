// ignore_for_file: avoid_print
// Generates every platform icon from assets/icon/icon.svg.
//
//   dart tool/make_icons.dart
//
// The SVG is the single source of truth; the generated PNG/ICO files are
// checked in (Android, Linux, Windows, web) because the build must not
// depend on this tool. Re-run it only when the SVG changes.
//
// SVG rasterization is delegated to an external renderer (resvg, the Rust
// one, via its CLI), not to a Dart package: this is a one-off authoring
// step, and adding an SVG rasterizer to the app's dependency set for it
// would be a package nobody asked for. Install it with:
//
//   cargo install resvg        # or: npx @resvg/resvg-js-cli
//
// and pass it explicitly if it is not on PATH:
//
//   dart tool/make_icons.dart --renderer "npx --yes @resvg/resvg-js-cli"
//
// PNG encoding (truecolor + alpha, zlib via dart:io) and ICO packing are
// done here in plain Dart, so the tool needs nothing but the renderer.

import 'dart:io';
import 'dart:typed_data';

/// Android launcher icon sizes per density bucket. The legacy 48 dp
/// launcher icon.
const _androidLauncher = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

/// Android adaptive icons: the foreground layer is 108 dp, of which the
/// system shows the middle 72 dp — the safe zone. The artwork is scaled to
/// that safe zone so no part of it is ever masked away.
const _androidAdaptive = <String, int>{
  'mdpi': 108,
  'hdpi': 162,
  'xhdpi': 216,
  'xxhdpi': 324,
  'xxxhdpi': 432,
};

/// Fraction of the adaptive foreground the system is guaranteed to show.
const _adaptiveSafeZone = 72 / 108;

/// Linux: one PNG per hicolor theme size, installed under
/// `share/icons/hicolor/<size>x<size>/apps` (and bundled for the window
/// icon).
const _linuxSizes = <int>[16, 24, 32, 48, 64, 128, 256, 512];

/// Windows .ico entries (the sizes Explorer and the taskbar pick from).
const _windowsIcoSizes = <int>[16, 24, 32, 48, 64, 128, 256];

Future<void> main(List<String> args) async {
  final renderer = _argValue(args, '--renderer') ?? 'resvg';
  final root = Directory.current;
  final svg = File('${root.path}/assets/icon/icon.svg');
  if (!svg.existsSync()) {
    stderr.writeln('missing ${svg.path}');
    exit(1);
  }
  final tmp = Directory.systemTemp.createTempSync('unvisited-icons');
  try {
    final rendered = <String, Uint8List>{};

    /// Rasterizes [source] at [size] px with a transparent background
    /// (so the artwork's own rounded corners survive), memoized: several
    /// platforms share a size, and each render is a process spawn.
    Future<Uint8List> raster(File source, int size) async {
      final key = '${source.path}@$size';
      final cached = rendered[key];
      if (cached != null) return cached;
      final out = File('${tmp.path}/icon-$size-${source.uri.pathSegments.last}');
      final result = await Process.run(_shell, [
        '-c',
        '$renderer --fit-width $size --background "#00000000" '
            '"${source.path}" "${out.path}"',
      ]);
      if (result.exitCode != 0 || !out.existsSync()) {
        stderr.writeln('renderer failed for ${size}px:\n'
            '${result.stdout}\n${result.stderr}');
        exit(1);
      }
      final png = out.readAsBytesSync();
      rendered[key] = png;
      return png;
    }

    Future<Uint8List> icon(int size) => raster(svg, size);

    // The adaptive foreground: the same artwork, scaled into the safe
    // zone of a transparent 108 dp canvas. Rendering the full icon and
    // letting the launcher crop it would double the rounded corners and
    // clip the road at the edges.
    final adaptiveSvg = File('${tmp.path}/adaptive.svg')
      ..writeAsStringSync(_adaptiveForegroundSvg(svg.readAsStringSync()));

    // --- Android legacy launcher icons ---
    for (final entry in _androidLauncher.entries) {
      final png = await icon(entry.value);
      _write(
        'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
        png,
      );
    }

    // --- Android adaptive icon foreground ---
    for (final entry in _androidAdaptive.entries) {
      final png = await raster(adaptiveSvg, entry.value);
      _write(
        'android/app/src/main/res/mipmap-${entry.key}/ic_launcher_foreground.png',
        png,
      );
    }

    // --- Linux ---
    for (final size in _linuxSizes) {
      _write('linux/icons/${size}x$size.png', await icon(size));
    }

    // --- Windows ---
    final icoImages = <int, Uint8List>{
      for (final size in _windowsIcoSizes) size: await icon(size),
    };
    _write('windows/runner/resources/app_icon.ico', _buildIco(icoImages));

    // --- Web ---
    _write('web/favicon.png', await icon(16));
    _write('web/icons/Icon-192.png', await icon(192));
    _write('web/icons/Icon-512.png', await icon(512));
    // Maskable icons are cropped to a circle by the platform; the artwork
    // inside the safe circle is what the template expects.
    _write('web/icons/Icon-maskable-192.png', await raster(adaptiveSvg, 192));
    _write('web/icons/Icon-maskable-512.png', await raster(adaptiveSvg, 512));

    // A 1024px master for store listings and documentation.
    _write('assets/icon/icon-1024.png', await icon(1024));
  } finally {
    tmp.deleteSync(recursive: true);
  }
  print('icons generated from assets/icon/icon.svg');
}

String get _shell => Platform.isWindows ? 'cmd' : 'sh';

String? _argValue(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

void _write(String relativePath, List<int> bytes) {
  final f = File(relativePath);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  print('  $relativePath (${bytes.length} bytes)');
}

/// Packs PNG images into a Windows .ico: one directory entry per image,
/// the payload being the PNG file itself (supported since Vista).
Uint8List _buildIco(Map<int, Uint8List> images) {
  final sizes = images.keys.toList()..sort();
  final header = BytesBuilder();
  header.add([0, 0]); // reserved
  header.add([1, 0]); // type 1 = icon
  header.add(_le16(sizes.length));

  var offset = 6 + 16 * sizes.length;
  final entries = BytesBuilder();
  final payload = BytesBuilder();
  for (final size in sizes) {
    final png = images[size]!;
    entries.add([size >= 256 ? 0 : size]); // width, 0 means 256
    entries.add([size >= 256 ? 0 : size]); // height
    entries.add([0]); // color count
    entries.add([0]); // reserved
    entries.add(_le16(1)); // color planes
    entries.add(_le16(32)); // bits per pixel
    entries.add(_le32(png.length));
    entries.add(_le32(offset));
    offset += png.length;
    payload.add(png);
  }
  return Uint8List.fromList([...header.toBytes(), ...entries.toBytes(), ...payload.toBytes()]);
}

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// Wraps the icon artwork in a 108 dp canvas, scaled to fit and centered in
/// the 72 dp safe zone, on a transparent background: the adaptive icon's
/// foreground layer.
///
/// The artwork's own background (the outer rounded rect and the map panel
/// behind the roads) is dropped: the adaptive icon draws its background as
/// a separate flat layer, and keeping them would paint a small rounded card
/// inside the launcher's mask. Only those two `<rect>` elements are
/// removed, matched by their exact opening tags, so the roads are
/// untouched.
///
/// The artwork is not the full 512 viewBox - the roads sit inside it - so
/// the layer is positioned from the artwork's own bounding box
/// ([_artworkBounds]) rather than from the canvas: the bbox center goes to
/// the canvas center, and it is scaled only if it would exceed the safe
/// zone. That keeps the icon visually the same size as the legacy one
/// while guaranteeing no launcher mask can clip it.
String _adaptiveForegroundSvg(String source) {
  var body = source
      .replaceFirst(RegExp(r'<svg[^>]*>'), '')
      .replaceFirst('</svg>', '');
  for (final rect in const [
    '<rect width="512" height="512" rx="115" fill="#1E2A3A"/>',
    '<rect x="56" y="56" width="400" height="400" rx="40" fill="#2E3F55"/>',
  ]) {
    if (!body.contains(rect)) {
      throw StateError('icon.svg no longer contains $rect - update '
          'make_icons.dart (and the adaptive background color) with it');
    }
    body = body.replaceFirst(rect, '');
  }

  const canvas = 512.0;
  const safe = canvas * _adaptiveSafeZone; // 72 dp of 108 dp
  final b = _artworkBounds;
  final artworkW = b.right - b.left;
  final artworkH = b.bottom - b.top;
  // Only shrink when the artwork would not fit the safe zone.
  final scale = [
    1.0,
    safe / artworkW,
    safe / artworkH,
  ].reduce((a, c) => a < c ? a : c);

  // Center the *scaled* artwork's bbox on the canvas center.
  final dx = canvas / 2 - (b.left + artworkW / 2) * scale;
  final dy = canvas / 2 - (b.top + artworkH / 2) * scale;
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" '
      'width="512" height="512">'
      '<g transform="translate(${dx.toStringAsFixed(2)} '
      '${dy.toStringAsFixed(2)}) scale(${scale.toStringAsFixed(4)})">'
      '$body'
      '</g></svg>';
}

/// Bounding box of the icon artwork (everything but the two background
/// rects), in the SVG's 512-unit coordinate space. Measured from the
/// paths and markers in assets/icon/icon.svg; the tool asserts the
/// artwork still fits the safe zone, so a redrawn icon that outgrows it
/// fails loudly instead of being clipped by a launcher mask.
const _artworkBounds = _Bounds(left: 138, top: 138, right: 373, bottom: 401);

class _Bounds {
  const _Bounds(
      {required this.left,
      required this.top,
      required this.right,
      required this.bottom});

  final double left;
  final double top;
  final double right;
  final double bottom;
}
