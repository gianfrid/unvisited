// ignore_for_file: avoid_print
// Anonymizes an exported debug log: quantizes every lat,lon pair to ~111 m
// so the file can be shared for analysis without leaking exact locations.
// Run with: dart tool/anonymize_debug_log.dart <in.log.gz> [out.log.gz]
//
// Gzipped input is detected by magic bytes (plain text is also accepted);
// the output keeps the input's compression and defaults to
// `<name>.anonymized.log.gz` next to the input.

import 'dart:convert';
import 'dart:io';

import 'package:unvisited/debug_log.dart';

void main(List<String> args) {
  if (args.isEmpty || args.length > 2 || args.contains('-h') || args.contains('--help')) {
    stderr.writeln(
      'usage: dart tool/anonymize_debug_log.dart <in.log.gz> [out.log.gz]',
    );
    exit(args.isEmpty ? 1 : 0);
  }
  final inPath = args[0];
  final outPath = args.length == 2 ? args[1] : _defaultOutPath(inPath);

  final inBytes = File(inPath).readAsBytesSync();
  final gzipped = inBytes.length >= 2 && inBytes[0] == 0x1f && inBytes[1] == 0x8b;
  final text = utf8.decode(gzipped ? gzip.decode(inBytes) : inBytes);
  final anonymized = anonymizeDebugLog(text);

  final outBytes = gzipped ? gzip.encode(utf8.encode(anonymized)) : utf8.encode(anonymized);
  File(outPath).writeAsBytesSync(outBytes);
  print('wrote $outPath');
}

String _defaultOutPath(String inPath) {
  if (inPath.endsWith('.log.gz')) return inPath.replaceAll('.log.gz', '.anonymized.log.gz');
  if (inPath.endsWith('.gz')) return inPath.replaceAll('.gz', '.anonymized.gz');
  return '$inPath.anonymized';
}
