# PLAN — Fix the startup-salvage UTF-8 corruption (Technical debt 1)

TODO unit: "Technical debt" item 1.

Goal: a staged recording whose track name contains non-ASCII characters
must survive the startup salvage byte-exact.

## Defect

`AppModel._salvageRecordings` reads the staged file as a UTF-8 string
(`readAsString`) and hands it back to the importer re-encoded with
`gpx.codeUnits` (`lib/ui/app_model.dart:666`) — UTF-16 code units, not
UTF-8 bytes. ASCII round-trips fine; any character above U+00FF in the
staged `<name>` (the stop-with-name dialog now asks the user for it)
becomes garbage bytes and the salvaged track imports under a corrupted
name (or fails parsing, worst case).

The regression test for the fix then exposed the same defect class one
layer down, in every XML parser: they decoded the whole file with
`String.fromCharCodes(bytes)` (`gpx_parser.dart`'s `_text`,
`tcx_parser.dart`, `kmz_parser.dart` twice — including the KML entries
inside the ZIP), mangling every non-ASCII character in any imported
GPX/TCX/KML/KMZ, not just salvaged ones. This unit fixes that too: the
XML file decode becomes `utf8.decode` with a `FormatException` mapped
to the existing "not valid UTF-8" `TrackParseException` (one GPX catch
was already written for `String.fromCharCodes`, which never throws —
now it actually guards). A non-ASCII name now round-trips byte-exact
through the unified pipeline, which the regression test rides.

## Implementation steps

1. `lib/ui/app_model.dart`: `gpx.codeUnits` → `utf8.encode(gpx)` (the
   `utf8` import is already there from the stop-with-name slice).
2. Same pattern in `test/app_model_test.dart`'s `killedGpxBytes` helper
   (line ~837): it re-encodes a staged file for the salvage tests with
   `codeUnits`; switch to `utf8.encode` so the helper is shape-correct
   for non-ASCII names too.
3. XML parsers decode file bytes as UTF-8 (gpx `_text`, tcx `parse`,
   kmz's two sites) with `FormatException` → the existing
   TrackParseException wording per format. The ASCII sniffer
   (`sniffHead`) intentionally stays code-unit based — it looks for
   ASCII markers only, as its comment says.
4. Unit test in the salvage group: a staged file with a non-ASCII name
   (accented characters, written UTF-8 from a `MemoryStageSink`) imports
   at startup with the catalog name exact and the salvage notice intact.
   Regression pins both layers (the import path is exercised end to
   end: importer → GPX parser → store → catalog).

## Out of scope

The ASCII `codeUnits` uses in parser tests and other test fixtures
(each literal is ASCII-only and correct); the writer, the stop path
(already `utf8.encode`) and the salvage repair logic are untouched.
Non-UTF-8 XMLs (e.g. ISO-8859-1-declared documents) are not supported
before or after: every producer in SPEC's scope writes UTF-8.

## Verification

`flutter analyze` clean; `flutter test` green including the new
non-ASCII salvage test.
