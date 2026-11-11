import 'dart:io';

import 'package:unvisited/import/kmz_parser.dart';
import 'package:unvisited/import/track_importer.dart';
import 'package:unvisited/import/track_parser.dart';
import 'package:unvisited/import/tcx_parser.dart';
import 'package:unvisited/import/gpx_parser.dart';
import 'package:unvisited/import/fit_parser.dart';
import 'package:unvisited/models/track.dart';


/// Loads a checked-in fixture as raw bytes.
List<int> fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

/// Small track parsers for edge tests.
final allParsers = <TrackParser>[
  GpxParser(),
  FitParser(),
  KmzParser(),
  TcxParser(),
];

TrackData parseFixture(String name, {String? filename}) =>
    TrackImporter().import(fixture(name), filename: filename);
