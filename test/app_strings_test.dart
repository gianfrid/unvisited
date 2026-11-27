import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/l10n/app_strings.dart';

/// Every string getter on [AppStrings], so the coverage test below cannot
/// silently miss one a new language forgot to translate. Parameterized
/// members are called with representative values.
Map<String, String> allStrings(AppStrings s) => {
      'importLabel': s.importLabel,
      'importTooltip': s.importTooltip,
      'fitTooltip': s.fitTooltip,
      'locateLabel': s.locateLabel,
      'locateTooltip': s.locateTooltip,
      'followReplayLabel': s.followReplayLabel,
      'followReplayTooltip': s.followReplayTooltip,
      'locating': s.locating,
      'recordLabel': s.recordLabel,
      'stopLabel': s.stopLabel,
      'recordDeclined': s.recordDeclined,
      'followReleasedHint': s.followReleasedHint,
      'cameraLabel': s.cameraLabel,
      'cameraTooltip': s.cameraTooltip,
      'photoAdded': s.photoAdded,
      'photoDeclined': s.photoDeclined,
      'photoFailed': s.photoFailed,
      'photoTakenAt(2026-11-24 10:30)': s.photoTakenAt('2026-11-24 10:30'),
      'photoSaveToGallery': s.photoSaveToGallery,
      'photoSavedToGallery': s.photoSavedToGallery,
      'photoSaveFailed': s.photoSaveFailed,
      'photoShare': s.photoShare,
      'photoDelete': s.photoDelete,
      'photoDeleteConfirmTitle': s.photoDeleteConfirmTitle,
      'photoReposition': s.photoReposition,
      'photoRepositionHint': s.photoRepositionHint,
      'photosSetting': s.photosSetting,
      'photosSettingSubtitle': s.photosSettingSubtitle,
      'pauseLabel': s.pauseLabel,
      'resumeLabel': s.resumeLabel,
      'statAvgSpeed': s.statAvgSpeed,
      'statDistance': s.statDistance,
      'statElapsed': s.statElapsed,
      'statMoving': s.statMoving,
      'statAltitude': s.statAltitude,
      'tracksLabel': s.tracksLabel,
      'settingsLabel': s.settingsLabel,
      'importTrackFiles': s.importTrackFiles,
      'importTrackFilesSubtitle': s.importTrackFilesSubtitle,
      'importFolder': s.importFolder,
      'importFolderSubtitle': s.importFolderSubtitle,
      'folderImportFailed': s.folderImportFailed,
      'importedCount(1)': s.importedCount(1),
      'importedCount(2)': s.importedCount(2),
      'duplicateCount(1)': s.duplicateCount(1),
      'duplicateCount(2)': s.duplicateCount(2),
      'skippedCount(1)': s.skippedCount(1),
      'skippedCount(2)': s.skippedCount(2),
      'failedCount(1)': s.failedCount(1),
      'failedCount(2)': s.failedCount(2),
      'nothingToImport': s.nothingToImport,
      'locationServiceDisabled': s.locationServiceDisabled,
      'locationPermissionDenied': s.locationPermissionDenied,
      'locationPermissionBlocked': s.locationPermissionBlocked,
      'locationUnavailable': s.locationUnavailable,
      'noTracksYet': s.noTracksYet,
      'noTracksHint': s.noTracksHint,
      'zoomIn': s.zoomIn,
      'zoomOut': s.zoomOut,
      'settingsTitle': s.settingsTitle,
      'aboutDescription': s.aboutDescription,
      'rotationModeNorth': s.rotationModeNorth,
      'rotationModeCourse': s.rotationModeCourse,
      'buildDate': s.buildDate('2026-11-12 17:41'),
      'githubRepository': s.githubRepository,
      'trackColor': s.trackColor,
      'trackColorSubtitle': s.trackColorSubtitle,
      'controlSide': s.controlSide,
      'controlSideSubtitle': s.controlSideSubtitle,
      'language': s.language,
      'languageSubtitle': s.languageSubtitle,
      'languageName(en)': s.languageName('en'),
      'languageName(it)': s.languageName('it'),
      'systemLanguage': s.systemLanguage,
      'left': s.left,
      'right': s.right,
      'theme': s.theme,
      'traceStyle': s.traceStyle,
      'traceStyleSubtitle': s.traceStyleSubtitle,
      'traceStyleCircles': s.traceStyleCircles,
      'traceStylePencil': s.traceStylePencil,
      'traceStyleInk': s.traceStyleInk,
      'themeSubtitle': s.themeSubtitle,
      'systemTheme': s.systemTheme,
      'lightTheme': s.lightTheme,
      'darkTheme': s.darkTheme,
      'deleteAllTracks': s.deleteAllTracks,
      'deleteConfirmTitle(X)': s.deleteConfirmTitle('X'),
      'deleteConfirmBody': s.deleteConfirmBody,
      'deleteConfirmGo': s.deleteConfirmGo,
      'deleteConfirmCancel': s.deleteConfirmCancel,
      'storedCount(1)': s.storedCount(1),
      'storedCount(2)': s.storedCount(2),
      'noStoredTracks': s.noStoredTracks,
      'deleteAllTracksQuestion': s.deleteAllTracksQuestion,
      'deleteAllTracksBody': s.deleteAllTracksBody(2),
      'cancel': s.cancel,
      'close': s.close,
      'delete': s.delete,
      'allTracksDeleted': s.allTracksDeleted,
      'selectAllTracks': s.selectAllTracks,
      'deselectAllTracks': s.deselectAllTracks,
      'nothingImportedYet': s.nothingImportedYet,
      'deleteTrack': s.deleteTrack,
      'pointCount(1)': s.pointCount(1),
      'pointCount(2)': s.pointCount(2),
      'tintName(green)': s.tintName('green'),
      'tintName(blue)': s.tintName('blue'),
      'tintName(orange)': s.tintName('orange'),
      'tintName(purple)': s.tintName('purple'),
      'tintName(red)': s.tintName('red'),
      'tintName(teal)': s.tintName('teal'),
      'tintName(amber)': s.tintName('amber'),
      'tintName(pink)': s.tintName('pink'),
      'selectionHideTooltip': s.selectionHideTooltip,
      'selectionColorTooltip': s.selectionColorTooltip,
      'selectionDismissTooltip': s.selectionDismissTooltip,
      'selectionTracksTooltip': s.selectionTracksTooltip,
      'memberPickToast': s.memberPickToast,
      'memberPickHide': s.memberPickHide,
      'memberPickHideOthers': s.memberPickHideOthers,
      'memberPickShow': s.memberPickShow,
      'areaHiddenToast': s.areaHiddenToast,
      'undoAction': s.undoAction,
      'trackMenuTooltip': s.trackMenuTooltip,
      'trackMenuInfo': s.trackMenuInfo,
      'trackMenuExport': s.trackMenuExport,
      'infoStart': s.infoStart,
      'infoFormat': s.infoFormat,
      'infoPoints': s.infoPoints,
      'infoDistance': s.infoDistance,
      'infoDuration': s.infoDuration,
      'infoMovingTime': s.infoMovingTime,
      'infoAvgSpeed': s.infoAvgSpeed,
      'trackStart(noon)': s.trackStart(DateTime.utc(2026, 6, 1, 12, 30)),
      'roadData': s.roadData,
      'roadDataSubtitle': s.roadDataSubtitle,
      'roadDataNone': s.roadDataNone,
      'roadDataChoose': s.roadDataChoose,
      'roadDataRemove': s.roadDataRemove,
      'roadDataInvalid': s.roadDataInvalid,
      'showUnvisitedRoads': s.showUnvisitedRoads,
      'showUnvisitedRoadsSubtitle': s.showUnvisitedRoadsSubtitle,
      'roadsUnvisitedInView(50)': s.roadsUnvisitedInView(50),
      'roadsUnvisitedInView(100)': s.roadsUnvisitedInView(100),
      'roadsUnvisitedUnknown': s.roadsUnvisitedUnknown,
      'batteryOptimization': s.batteryOptimization,
      'batteryExcluded': s.batteryExcluded,
      'batteryAdvisory': s.batteryAdvisory,
      'salvagedRecording': s.salvagedRecording('Morning walk'),
      'keepScreenOn': s.keepScreenOn,
      'keepScreenOnSubtitle': s.keepScreenOnSubtitle,
      'debugLogging': s.debugLogging,
      'debugLoggingSubtitle': s.debugLoggingSubtitle,
      'saveDebugLog': s.saveDebugLog,
      'debugLogSaved': s.debugLogSaved,
      'exportCatalog': s.exportCatalog,
      'importCatalog': s.importCatalog,
      'catalogImported(2)': s.catalogImported(2),
      'catalogImportFailed': s.catalogImportFailed,
    };

void main() {
  test('every supported language translates every string', () {
    final english = allStrings(const EnglishStrings());
    for (final entry in AppStrings.supported.entries) {
      final strings = allStrings(entry.value);
      expect(strings.keys, english.keys,
          reason: '${entry.key} must cover the same strings');
      for (final key in strings.keys) {
        expect(strings[key], isNotEmpty,
            reason: '${entry.key}.$key is empty');
      }
    }
  });

  test('Italian is actually translated, not English copy-pasted', () {
    // A few strings legitimately match English (the app name is not in
    // here, but "Delete"/"Delete" style coincidences are possible), so
    // compare the set as a whole rather than one by one.
    final english = allStrings(const EnglishStrings());
    final italian = allStrings(const ItalianStrings());
    final identical = [
      for (final key in english.keys)
        if (english[key] == italian[key]) key,
    ];
    expect(identical.length, lessThan(english.length ~/ 4),
        reason: 'too many untranslated strings: $identical');
  });

  test('Italian pluralizes counts', () {
    const it = ItalianStrings();
    expect(it.importedCount(1), '1 importata');
    expect(it.importedCount(3), '3 importate');
    expect(it.pointCount(1), '1 punti');
    expect(it.storedCount(1), '1 archiviata');
    expect(it.duplicateCount(2), '2 duplicate');
  });

  test('unknown locales fall back to English', () {
    expect(AppStrings.of(const Locale('en')), isA<EnglishStrings>());
    expect(AppStrings.of(const Locale('it')), isA<ItalianStrings>());
    // A regional variant resolves through its language code.
    expect(AppStrings.of(const Locale('it', 'CH')), isA<ItalianStrings>());
    expect(AppStrings.of(const Locale('fr')), isA<EnglishStrings>());
    expect(AppStrings.of(const Locale('de', 'DE')), isA<EnglishStrings>());
  });

  test('supported locales cover every language with strings', () {
    final codes = AppStrings.supportedLocales.map((l) => l.languageCode);
    expect(codes.toSet(), AppStrings.supported.keys.toSet());
    // The first supported locale is the fallback.
    expect(AppStrings.supportedLocales.first.languageCode, 'en');
  });

  testWidgets('Localizations.localeOf resolves to a supported language',
      (tester) async {
    // Without a delegate, MaterialApp leaves localeOf at the raw system
    // locale and an unsupported language would reach AppStrings.of as e.g.
    // 'fr' - fine by the fallback, but the resolved locale should already
    // be one the app speaks.
    late Locale resolved;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        DefaultMaterialLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
        _TestLocaleDelegate(),
      ],
      supportedLocales: AppStrings.supportedLocales,
      // The delegate loads asynchronously, so the first frame has no
      // localizations yet.
      home: Builder(builder: (context) {
        resolved = Localizations.localeOf(context);
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();
    expect(AppStrings.supported.containsKey(resolved.languageCode), isTrue);
  });
}

/// Mirrors `_AppLocaleDelegate` in main.dart (which is private); the point
/// of the test above is the supportedLocales resolution, not the delegate.
class _TestLocaleDelegate extends LocalizationsDelegate<AppStrings> {
  const _TestLocaleDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppStrings.supported.containsKey(locale.languageCode);

  @override
  Future<AppStrings> load(Locale locale) async => AppStrings.of(locale);

  @override
  bool shouldReload(_TestLocaleDelegate old) => false;
}
