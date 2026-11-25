import 'package:flutter/widgets.dart';

/// Every user-visible string in the app, per language.
///
/// Hand-rolled instead of `flutter_localizations` + ARB: the app has one
/// screen, so the generated-localization machinery (and its `intl`
/// dependency) would be more moving parts than the ~40 strings it would
/// carry. The rules stay the same either way — no user-visible text is
/// hardcoded in widgets, it is looked up here through [AppStrings.of].
///
/// Adding a language means adding a subclass and one line in
/// [AppStrings.supported]; the tests fail on any missing override.
abstract class AppStrings {
  const AppStrings();

  /// Resolves the strings for [locale], falling back to English for
  /// languages the app does not speak. Callers pass the locale MaterialApp
  /// resolved, so an unsupported system language never yields a half
  /// translated UI.
  factory AppStrings.of(Locale locale) =>
      supported[locale.languageCode] ?? const EnglishStrings();

  /// Language code to strings. The first entry is the fallback.
  static const supported = <String, AppStrings>{
    'en': EnglishStrings(),
    'it': ItalianStrings(),
  };

  /// Convenience for widgets: the strings for the current context locale.
  static AppStrings ofContext(BuildContext context) =>
      AppStrings.of(Localizations.localeOf(context));

  /// The locales MaterialApp should support, in the order it prefers them.
  static const supportedLocales = <Locale>[Locale('en'), Locale('it')];

  // Header actions (captions are short: the toolbar is 48 px per action).
  String get importLabel;
  String get importTooltip;
  String get fitTooltip;
  String get locateLabel;
  String get locateTooltip;
  String get followReplayLabel;
  String get followReplayTooltip;

  /// The toolbar's recording action; hidden where the platform has no
  /// location support (the session could never start there).
  String get recordLabel;

  /// The recording action's stop; the chip meanwhile shows the live
  /// duration and distance (meters — the engine's haversine sum, not a
  /// straight line).
  String get stopLabel;

  /// Says why recording could not start after the user declined the
  /// while-in-use permission; told instead of a button that silently
  /// did nothing.
  String get recordDeclined;

  /// The record cluster's camera action: takes a geotagged photo through
  /// the system camera app, tagged with the freshest fix in hand. Shown
  /// only where a location fix exists (and hidden by the photos setting).
  String get cameraLabel;
  String get cameraTooltip;

  /// Camera outcomes, toasted on the map: the pin appeared, the user
  /// backed out of the camera app (not an error), or the capture failed.
  String get photoAdded;
  String get photoDeclined;
  String get photoFailed;

  /// The photo preview dialog: its caption stamps the capture time, its
  /// actions offer the gallery export, the share sheet, and deletion —
  /// deletion asks first, like the recording's discard.
  String photoTakenAt(String date);
  String get photoSaveToGallery;
  String get photoSavedToGallery;
  String get photoSaveFailed;
  String get photoShare;
  String get photoDelete;
  String get photoDeleteConfirmTitle;

  /// Repositioning a photo: the preview's Reposition action arms a
  /// tap-to-move mode — the banner says where the next map tap lands the
  /// photo, and Cancel leaves it where it was.
  String get photoReposition;
  String get photoRepositionHint;

  /// The Settings row for the photos feature (Android-only): while off,
  /// the camera button and the photo pins hide; stored photos are kept.
  String get photosSetting;
  String get photosSettingSubtitle;

  /// The record-mode dashboard's pause action; paired with [recordLabel]'s
  /// slot. Pausing closes the current `<trkseg>` (the session's existing
  /// semantics); resuming opens the next one.
  String get pauseLabel;
  String get resumeLabel;

  /// The stop-with-name dialog: the stop's title and the name field's
  /// label (the field is seeded with the current date-time timestamp).
  String get stopRecordingTitle;
  String get recordingNameLabel;

  /// The stop dialog's actions: Save finalizes and imports the track;
  /// Discard (two-step — [discardConfirmTitle] asks first) ends the
  /// session and throws the staged track away.
  String get saveLabel;
  String get discardLabel;
  String get discardConfirmTitle;

  // Recording dashboard (labels of the stats panel; the values carry
  // their units code-side like the distances do).
  String get statAvgSpeed;
  String get statDistance;
  String get statElapsed;
  String get statMoving;
  String get statAltitude;

  /// Shown while a fix is being acquired: the GPS can take seconds to
  /// answer, and an unchanged button reads as a dead one.
  String get locating;  String get tracksLabel;
  String get settingsLabel;

  // Import sheet.
  String get importTrackFiles;
  String get importTrackFilesSubtitle;
  String get importFolder;
  String get importFolderSubtitle;
  String get folderImportFailed;

  // Import summary toast.
  String importedCount(int count);
  String duplicateCount(int count);
  String skippedCount(int count);
  String failedCount(int count);
  String get nothingToImport;

  // Locate failures.
  String get locationServiceDisabled;
  String get locationPermissionDenied;
  String get locationPermissionBlocked;
  String get locationUnavailable;

  // Empty map.
  String get noTracksYet;
  String get noTracksHint;

  // Zoom slider.
  String get zoomIn;
  String get zoomOut;

  // Settings sheet.
  String get settingsTitle;
  String get aboutDescription;
  String buildDate(String date);

  /// The About card's link to the project repository; the URL is the
  /// const [repoUrl] in settings_sheet.dart, not a translated string.
  String get githubRepository;
  String get trackColor;
  String get trackColorSubtitle;
  String get controlSide;
  String get controlSideSubtitle;

  // Base tile style (standard OSM raster or CyclOSM cycle tiles).
  String get mapLayer;
  String get mapLayerSubtitle;
  String get standardLayer;
  String get cycleLayer;

  // Rotation mode names (control pill button tooltip, Settings segments).
  String get rotationModeNorth;
  String get rotationModeCourse;

  String get language;
  String get languageSubtitle;

  /// Name of a language as shown in the picker, written in that language
  /// (so a user who cannot read the current UI language still finds
  /// theirs). [code] is a supported language code.
  String languageName(String code);

  /// The "follow the device language" option.
  String get systemLanguage;
  String get left;
  String get right;

  // Theme.
  String get theme;
  String get traceStyle;
  String get traceStyleSubtitle;
  String get traceStyleCircles;
  String get traceStylePencil;
  String get traceStyleInk;
  String get themeSubtitle;
  String get systemTheme;
  String get lightTheme;
  String get darkTheme;

  // Road data (side-loaded .unvisited-roads region file).
  String get roadData;
  String get roadDataSubtitle;
  String get roadDataNone;
  String get roadDataChoose;
  String get roadDataRemove;
  String get roadDataInvalid;
  String get showUnvisitedRoads;
  String get showUnvisitedRoadsSubtitle;
  String roadsUnvisitedInView(int percent);
  String get roadsUnvisitedUnknown;

  // Battery optimization (Android-only, soft advisory for recording).
  String get batteryOptimization;
  String get batteryExcluded;
  String get batteryAdvisory;

  // Startup salvage: a killed session's staged recording was imported.
  String salvagedRecording(String name);

  // Keep screen on while recording (the Settings row; the latch applies
  // live, even mid-session).
  String get keepScreenOn;
  String get keepScreenOnSubtitle;

  // Debug logging (dev aid): the Settings switch and the save-log action.
  String get debugLogging;
  String get debugLoggingSubtitle;
  String get saveDebugLog;
  String get debugLogSaved;

  String get deleteAllTracks;
  String storedCount(int count);
  String get noStoredTracks;

  // Delete-all confirmation.
  String get deleteAllTracksQuestion;
  String deleteAllTracksBody(int count);
  String get cancel;
  String get close;
  String get delete;
  String get allTracksDeleted;

  // Tracks drawer.
  String get selectAllTracks;
  String get deselectAllTracks;
  String get nothingImportedYet;
  String get deleteTrack;

  /// The confirmation before a delete runs (swipe or button): names the
  /// track, says the file goes with it irreversibly, and offers
  /// [deleteConfirmGo] vs [deleteConfirmCancel]. A swipe always shows it —
  /// one accidental gesture must not destroy the track.
  String deleteConfirmTitle(String trackName);
  String get deleteConfirmBody;

  /// The confirmation's destructive and dismissive actions.
  String get deleteConfirmGo;
  String get deleteConfirmCancel;
  String pointCount(int count);

  // Tint swatch names (keys live in track_colors.dart).
  String tintName(String key);

  // Selection bar (aggregate tracks and selection): hide, recolor, dismiss,
  // and the member-picking bubble's labeled actions.
  String get selectionHideTooltip;
  String get selectionColorTooltip;
  String get selectionDismissTooltip;
  String get selectionTracksTooltip;
  String get memberPickToast;
  String get memberPickHide;
  String get memberPickHideOthers;
  String get memberPickShow;
  String get areaHiddenToast;
  String get undoAction;

  // Per-track menu (⋮ on a track tile): Info / Delete / Export.
  String get trackMenuTooltip;
  String get trackMenuInfo;
  String get trackMenuExport;

  // Track playback (the ⋮ menu entry and the replay bar): the entry
  // starts the replay, the bar carries play/pause/replay, the speed
  // chip and close. Pause reuses [pauseLabel].
  String get trackMenuPlayback;
  String get playbackPlay;
  String get playbackReplay;
  String get playbackSpeed;
  String get playbackClose;

  // The track info dialog's labels (values are plain numbers/formats).
  String get infoStart;
  String get infoFormat;
  String get infoPoints;
  String get infoDistance;
  String get infoDuration;
  String get infoMovingTime;
  String get infoAvgSpeed;

  /// A track's start date/time, locale-formatted for the info dialog.
  String trackStart(DateTime start);

  // Export feedback (a toast on success and failure).
  String get exportDone;
  String get exportFailed;

  // Whole-catalog export/import (Settings rows).
  String get exportCatalog;
  String get importCatalog;
  String catalogImported(int count);
  String get catalogImportFailed;
}

class EnglishStrings extends AppStrings {
  const EnglishStrings();

  @override
  String get importLabel => 'Import';
  @override
  String get importTooltip => 'Import tracks';
  @override
  String get fitTooltip => 'Fit tracks';
  @override
  String get selectionHideTooltip => 'Hide this area';
  @override
  String get selectionColorTooltip => 'Change the color';
  @override
  String get selectionDismissTooltip => 'Dismiss selection';
  @override
  String get selectionTracksTooltip => 'Tracks in this area';
  @override
  String get memberPickToast => 'Tap a track to pick it';
  @override
  String get memberPickHide => 'Hide this track';
  @override
  String get memberPickHideOthers => 'Hide the others';
  @override
  String get memberPickShow => 'Show this track';
  @override
  String get areaHiddenToast => 'Area hidden';
  @override
  String get undoAction => 'Undo';
  @override
  String get trackMenuTooltip => 'Track actions';
  @override
  String get trackMenuInfo => 'Info';
  @override
  String get trackMenuExport => 'Export';
  @override
  String get trackMenuPlayback => 'Playback';
  @override
  String get playbackPlay => 'Play';
  @override
  String get playbackReplay => 'Replay';
  @override
  String get playbackSpeed => 'Playback speed';
  @override
  String get playbackClose => 'Close playback';
  @override
  String get infoStart => 'Started';
  @override
  String get infoFormat => 'Format';
  @override
  String get infoPoints => 'Points';
  @override
  String get infoDistance => 'Distance';
  @override
  String get infoDuration => 'Duration';
  @override
  String get infoMovingTime => 'Moving time';
  @override
  String get infoAvgSpeed => 'Average speed';
  @override
  String trackStart(DateTime start) =>
      '${start.year.toString().padLeft(4, '0')}-'
      '${start.month.toString().padLeft(2, '0')}-'
      '${start.day.toString().padLeft(2, '0')} '
      '${start.hour.toString().padLeft(2, '0')}:'
      '${start.minute.toString().padLeft(2, '0')}';
  @override
  String get exportDone => 'Track exported';
  @override
  String get exportFailed => 'Export failed';
  @override
  String get exportCatalog => 'Export all tracks';
  @override
  String get importCatalog => 'Import from export';
  @override
  String catalogImported(int count) =>
      '$count track(s) imported — duplicates skipped';
  @override
  String get catalogImportFailed => 'Import failed — not an Unvisited export';
  @override
  String get locateLabel => 'Locate';
  @override
  String get followReplayLabel => 'Follow';
  @override
  String get followReplayTooltip => 'Center on the replay cursor';
  @override
  String get locateTooltip => 'Center on current position';
  @override
  String get locating => 'Locating…';
  @override
  String get recordLabel => 'Record';
  @override
  String get stopLabel => 'Stop';
  @override
  String get recordDeclined => 'Recording needs location permission';
  @override
  String get cameraLabel => 'Camera';
  @override
  String get cameraTooltip => 'Take a photo here';
  @override
  String get photoAdded => 'Photo added to the map';
  @override
  String get photoDeclined => 'No photo taken';
  @override
  String get photoFailed => 'The camera could not be opened';
  @override
  String photoTakenAt(String date) => 'Taken $date';
  @override
  String get photoSaveToGallery => 'Save to gallery';
  @override
  String get photoSavedToGallery => 'Saved to the gallery';
  @override
  String get photoSaveFailed => 'Could not save to the gallery';
  @override
  String get photoShare => 'Share';
  @override
  String get photoDelete => 'Delete';
  @override
  String get photoDeleteConfirmTitle =>
      'Delete this photo? The file is removed from the app.';
  @override
  String get photoReposition => 'Reposition';
  @override
  String get photoRepositionHint =>
      'Tap on the map where the photo was taken';
  @override
  String get photosSetting => 'Photos';
  @override
  String get photosSettingSubtitle =>
      'Camera button and photo pins on the map; stored photos are kept when off';
  @override
  String get pauseLabel => 'Pause';
  @override
  String get resumeLabel => 'Resume';
  @override
  String get stopRecordingTitle => 'Stop recording';
  @override
  String get recordingNameLabel => 'Track name';
  @override
  String get saveLabel => 'Save';
  @override
  String get discardLabel => 'Discard';
  @override
  String get discardConfirmTitle => 'Discard this recording?';
  @override
  String get statAvgSpeed => 'Avg speed';
  @override
  String get statDistance => 'Distance';
  @override
  String get statElapsed => 'Elapsed';
  @override
  String get statMoving => 'Moving';
  @override
  String get statAltitude => 'Altitude';
  @override
  String get tracksLabel => 'Tracks';
  @override
  String get settingsLabel => 'Settings';

  @override
  String get importTrackFiles => 'Track files';
  @override
  String get importTrackFilesSubtitle => 'GPX, FIT, KMZ or TCX — one or more';
  @override
  String get importFolder => 'A folder';
  @override
  String get importFolderSubtitle =>
      'Every supported file below it is imported';
  @override
  String get folderImportFailed => 'Folder import failed';

  @override
  String importedCount(int count) => '$count imported';
  @override
  String duplicateCount(int count) => '$count duplicates';
  @override
  String skippedCount(int count) => '$count skipped';
  @override
  String failedCount(int count) => '$count failed';
  @override
  String get nothingToImport => 'Nothing to import';

  @override
  String get locationServiceDisabled =>
      'Location services are off — turn them on to locate';
  @override
  String get locationPermissionDenied =>
      'No location permission — Locate needs it to center the map';
  @override
  String get locationPermissionBlocked =>
      'Location permission is blocked — allow it in system settings';
  @override
  String get locationUnavailable =>
      'Location unavailable — permission denied or no fix';

  @override
  String get noTracksYet => 'No tracks yet';
  @override
  String get noTracksHint =>
      'Import GPX, FIT, KMZ or TCX files — pick a folder or '
      'single files, or share a track from another app.';

  @override
  String get zoomIn => 'Zoom in';
  @override
  String get zoomOut => 'Zoom out';

  @override
  String get settingsTitle => 'Settings';
  @override
  String get aboutDescription =>
      'Track recording and exploration on OpenStreetMap (GPX, FIT, KMZ '
      'and TCX). Imports and recordings stay on your device; only the '
      'map tiles are fetched.';
  @override
  String buildDate(String date) => 'Build date: $date';
  @override
  String get githubRepository => 'GitHub repository';
  @override
  String get trackColor => 'Trace color';
  @override
  String get trackColorSubtitle =>
      'Color of the live recording trace on the map';
  @override
  String get controlSide => 'Control side';
  @override
  String get controlSideSubtitle =>
      'Screen edge the map control buttons sit on';
  @override
  String get mapLayer => 'Map type';
  @override
  String get mapLayerSubtitle => 'Tiles of the base map';
  @override
  String get standardLayer => 'Standard';
  @override
  String get cycleLayer => 'Cycle (CyclOSM)';
  @override
  String get rotationModeNorth => 'North up';
  @override
  String get rotationModeCourse => 'Course up';
  @override
  String get language => 'Language';
  @override
  String get languageSubtitle => 'Language of the app';
  @override
  String languageName(String code) => switch (code) {
    'en' => 'English',
    'it' => 'Italiano',
    _ => code,
  };
  @override
  String get systemLanguage => 'System language';
  @override
  String get left => 'Left';
  @override
  String get right => 'Right';
  @override
  String get theme => 'Theme';
  @override
  String get themeSubtitle => 'Appearance of the app';
  @override
  String get traceStyle => 'Trace style';
  @override
  String get traceStyleSubtitle => 'How explored areas are drawn';
  @override
  String get traceStyleCircles => 'Circles';
  @override
  String get traceStylePencil => 'Pencil';
  @override
  String get traceStyleInk => 'Ink';
  @override
  String get systemTheme => 'System';
  @override
  String get lightTheme => 'Light';
  @override
  String get darkTheme => 'Dark';

  @override
  String get roadData => 'Road data';
  @override
  String get roadDataSubtitle =>
      'Roads file that unlocks the explored corridors';
  @override
  String get roadDataNone => 'None set';
  @override
  String get roadDataChoose => 'Choose a roads file…';
  @override
  String get roadDataRemove => 'Remove road data';
  @override
  String get roadDataInvalid => 'That file is not an Unvisited roads file';
  @override
  String get showUnvisitedRoads => 'Show unvisited roads';
  @override
  String get showUnvisitedRoadsSubtitle =>
      'Dashed: the roads this view still has left';
  @override
  String roadsUnvisitedInView(int percent) => 'Unvisited roads here: $percent%';
  @override
  String get roadsUnvisitedUnknown => 'Unvisited roads here: —';

  @override
  String get batteryOptimization => 'Battery optimization';
  @override
  String get batteryExcluded =>
      'Recording is exempt from the battery manager';
  @override
  String get batteryAdvisory =>
      'Battery saving can interrupt recording — tap to manage';
  @override
  String salvagedRecording(String name) =>
      'Recovered unfinished recording: $name';

  @override
  String get keepScreenOn => 'Keep screen on while recording';
  @override
  String get keepScreenOnSubtitle =>
      'The screen stays on during a recording session';
  @override
  String get debugLogging => 'Debug logging';
  @override
  String get debugLoggingSubtitle =>
      'Collect an in-app log of location, recording and camera events';
  @override
  String get saveDebugLog => 'Save debug log';
  @override
  String get debugLogSaved => 'Debug log saved (gzip-compressed)';

  @override
  String get deleteAllTracks => 'Delete all tracks';
  @override
  String storedCount(int count) => '$count stored';
  @override
  String get noStoredTracks => 'No stored tracks';

  @override
  String get deleteAllTracksQuestion => 'Delete all tracks?';
  @override
  String deleteAllTracksBody(int count) =>
      'This permanently deletes all $count stored tracks. '
      'The original files you imported them from are not touched.';
  @override
  String get cancel => 'Cancel';
  @override
  String get close => 'Close';
  @override
  String get delete => 'Delete';
  @override
  String get allTracksDeleted => 'All tracks deleted';

  @override
  String get selectAllTracks => 'Select all tracks';
  @override
  String get deselectAllTracks => 'Deselect all tracks';
  @override
  String get nothingImportedYet => 'Nothing imported yet';
  @override
  String get deleteTrack => 'Delete track';
  @override
  String deleteConfirmTitle(String trackName) => 'Delete "$trackName"?';
  @override
  String get deleteConfirmBody =>
      'The track file is deleted with it. This cannot be undone.';
  @override
  String get deleteConfirmGo => 'Delete';
  @override
  String get deleteConfirmCancel => 'Cancel';
  @override
  String pointCount(int count) => '$count pts';

  @override
  String tintName(String key) => switch (key) {
    'green' => 'Green',
    'blue' => 'Blue',
    'orange' => 'Orange',
    'purple' => 'Purple',
    'red' => 'Red',
    'teal' => 'Teal',
    'amber' => 'Amber',
    'pink' => 'Pink',
    _ => key,
  };
}

class ItalianStrings extends AppStrings {
  const ItalianStrings();

  @override
  String get importLabel => 'Importa';
  @override
  String get importTooltip => 'Importa tracce';
  @override
  String get fitTooltip => 'Inquadra le tracce';
  @override
  String get selectionHideTooltip => 'Nascondi quest\'area';
  @override
  String get selectionColorTooltip => 'Cambia il colore';
  @override
  String get selectionDismissTooltip => 'Annulla la selezione';
  @override
  String get selectionTracksTooltip => 'Tracce in quest\'area';
  @override
  String get memberPickToast => 'Tocca una traccia per sceglierla';
  @override
  String get memberPickHide => 'Nascondi questa traccia';
  @override
  String get memberPickHideOthers => 'Nascondi le altre';
  @override
  String get memberPickShow => 'Mostra questa traccia';
  @override
  String get areaHiddenToast => 'Area nascosta';
  @override
  String get undoAction => 'Annulla';
  @override
  String get trackMenuTooltip => 'Azioni traccia';
  @override
  String get trackMenuInfo => 'Info';
  @override
  String get trackMenuExport => 'Esporta';
  @override
  String get trackMenuPlayback => 'Riproduci';
  @override
  String get playbackPlay => 'Riproduci';
  @override
  String get playbackReplay => 'Ripeti';
  @override
  String get playbackSpeed => 'Velocità di riproduzione';
  @override
  String get playbackClose => 'Chiudi la riproduzione';
  @override
  String get infoStart => 'Iniziata';
  @override
  String get infoFormat => 'Formato';
  @override
  String get infoPoints => 'Punti';
  @override
  String get infoDistance => 'Distanza';
  @override
  String get infoDuration => 'Durata';
  @override
  String get infoMovingTime => 'Tempo in movimento';
  @override
  String get infoAvgSpeed => 'Velocità media';
  @override
  String trackStart(DateTime start) =>
      '${start.day.toString().padLeft(2, '0')}/'
      '${start.month.toString().padLeft(2, '0')}/'
      '${start.year.toString().padLeft(4, '0')} '
      '${start.hour.toString().padLeft(2, '0')}:'
      '${start.minute.toString().padLeft(2, '0')}';
  @override
  String get exportDone => 'Traccia esportata';
  @override
  String get exportFailed => 'Esportazione non riuscita';
  @override
  String get exportCatalog => 'Esporta tutte le tracce';
  @override
  String get importCatalog => 'Importa da esportazione';
  @override
  String catalogImported(int count) =>
      '$count tracce importate — duplicati ignorati';
  @override
  String get catalogImportFailed =>
      'Importazione non riuscita — non è un’esportazione di Unvisited';
  @override
  String get locateLabel => 'Posizione';
  @override
  String get followReplayLabel => 'Segui';
  @override
  String get followReplayTooltip => 'Centra sul cursore della riproduzione';
  @override
  String get locateTooltip => 'Centra sulla posizione attuale';
  @override
  String get locating => 'Localizzazione…';
  @override
  String get recordLabel => 'Registra';
  @override
  String get stopLabel => 'Ferma';
  @override
  String get recordDeclined => 'La registrazione richiede la posizione';
  @override
  String get cameraLabel => 'Foto';
  @override
  String get cameraTooltip => 'Scatta una foto qui';
  @override
  String get photoAdded => 'Foto aggiunta alla mappa';
  @override
  String get photoDeclined => 'Nessuna foto scattata';
  @override
  String get photoFailed => 'Impossibile aprire la fotocamera';
  @override
  String photoTakenAt(String date) => 'Scattata il $date';
  @override
  String get photoSaveToGallery => 'Salva nella galleria';
  @override
  String get photoSavedToGallery => 'Salvata nella galleria';
  @override
  String get photoSaveFailed => 'Impossibile salvare nella galleria';
  @override
  String get photoShare => 'Condividi';
  @override
  String get photoDelete => 'Elimina';
  @override
  String get photoDeleteConfirmTitle =>
      'Eliminare questa foto? Il file viene rimosso dall\'app.';
  @override
  String get photoReposition => 'Riposiziona';
  @override
  String get photoRepositionHint =>
      'Tocca la mappa dove è stata scattata la foto';
  @override
  String get photosSetting => 'Foto';
  @override
  String get photosSettingSubtitle =>
      'Pulsante fotocamera e pin sulla mappa; le foto archiviate restano anche se disattivato';
  @override
  String get pauseLabel => 'Pausa';
  @override
  String get resumeLabel => 'Riprendi';
  @override
  String get stopRecordingTitle => 'Ferma la registrazione';
  @override
  String get recordingNameLabel => 'Nome della traccia';
  @override
  String get saveLabel => 'Salva';
  @override
  String get discardLabel => 'Scarta';
  @override
  String get discardConfirmTitle => 'Scartare questa registrazione?';
  @override
  String get statAvgSpeed => 'Media';
  @override
  String get statDistance => 'Distanza';
  @override
  String get statElapsed => 'Trascorso';
  @override
  String get statMoving => 'In movimento';
  @override
  String get statAltitude => 'Altitudine';
  @override
  String get tracksLabel => 'Tracce';
  @override
  String get settingsLabel => 'Impostazioni';

  @override
  String get importTrackFiles => 'File di traccia';
  @override
  String get importTrackFilesSubtitle =>
      'GPX, FIT, KMZ o TCX — anche più di uno';
  @override
  String get importFolder => 'Una cartella';
  @override
  String get importFolderSubtitle =>
      'Viene importato ogni file supportato al suo interno';
  @override
  String get folderImportFailed => 'Importazione della cartella non riuscita';

  // Italian pluralizes the verb, so the counts carry a one/other form
  // rather than a bare number.
  @override
  String importedCount(int count) =>
      count == 1 ? '1 importata' : '$count importate';
  @override
  String duplicateCount(int count) =>
      count == 1 ? '1 duplicata' : '$count duplicate';
  @override
  String skippedCount(int count) => count == 1 ? '1 saltata' : '$count saltate';
  @override
  String failedCount(int count) =>
      count == 1 ? '1 non riuscita' : '$count non riuscite';
  @override
  String get nothingToImport => 'Niente da importare';

  @override
  String get locationServiceDisabled =>
      'Servizi di localizzazione disattivati — attivali per usare Posizione';
  @override
  String get locationPermissionDenied =>
      'Nessun permesso di localizzazione — serve per centrare la mappa';
  @override
  String get locationPermissionBlocked =>
      'Permesso di localizzazione bloccato — consentilo nelle impostazioni '
      'di sistema';
  @override
  String get locationUnavailable =>
      'Posizione non disponibile — permesso negato o nessun segnale';

  @override
  String get noTracksYet => 'Ancora nessuna traccia';
  @override
  String get noTracksHint =>
      'Importa file GPX, FIT, KMZ o TCX — scegli una cartella o '
      'singoli file, oppure condividi una traccia da un\'altra app.';

  @override
  String get zoomIn => 'Ingrandisci';
  @override
  String get zoomOut => 'Riduci';

  @override
  String get settingsTitle => 'Impostazioni';
  @override
  String get aboutDescription =>
      'Registrazione ed esplorazione di tracce su OpenStreetMap (GPX, '
      'FIT, KMZ e TCX). Importazioni e registrazioni restano sul tuo '
      'dispositivo; solo i riquadri della mappa vengono scaricati.';
  @override
  String buildDate(String date) => 'Data di build: $date';
  @override
  String get githubRepository => 'Repository GitHub';
  @override
  String get trackColor => 'Colore della traccia';
  @override
  String get trackColorSubtitle =>
      'Colore della traccia live in registrazione sulla mappa';
  @override
  String get controlSide => 'Lato dei controlli';
  @override
  String get controlSideSubtitle =>
      'Lato dello schermo su cui si trovano i pulsanti di controllo';
  @override
  String get mapLayer => 'Tipo mappa';
  @override
  String get mapLayerSubtitle => 'Tile della mappa base';
  @override
  String get standardLayer => 'Standard';
  @override
  String get cycleLayer => 'Ciclo (CyclOSM)';
  @override
  String get rotationModeNorth => 'Nord su';
  @override
  String get rotationModeCourse => 'Percorso su';
  @override
  String get language => 'Lingua';
  @override
  String get languageSubtitle => "Lingua dell'app";
  @override
  String languageName(String code) => switch (code) {
    'en' => 'English',
    'it' => 'Italiano',
    _ => code,
  };
  @override
  String get systemLanguage => 'Lingua di sistema';
  @override
  String get left => 'Sinistra';
  @override
  String get right => 'Destra';
  @override
  String get theme => 'Tema';
  @override
  String get themeSubtitle => "Aspetto dell'app";
  @override
  String get traceStyle => 'Stile della traccia';
  @override
  String get traceStyleSubtitle => 'Come vengono disegnate le aree esplorate';
  @override
  String get traceStyleCircles => 'Cerchi';
  @override
  String get traceStylePencil => 'Matita';
  @override
  String get traceStyleInk => 'Inchiostro';
  @override
  String get systemTheme => 'Sistema';
  @override
  String get lightTheme => 'Chiaro';
  @override
  String get darkTheme => 'Scuro';

  @override
  String get roadData => 'Dati stradali';
  @override
  String get roadDataSubtitle => 'File di strade che sblocca i corridoi';
  @override
  String get roadDataNone => 'Nessuno impostato';
  @override
  String get roadDataChoose => 'Scegli un file di strade…';
  @override
  String get roadDataRemove => 'Rimuovi i dati stradali';
  @override
  String get roadDataInvalid =>
      'Questo file non è un file di strade di Unvisited';
  @override
  String get showUnvisitedRoads => 'Mostra le strade non visitate';
  @override
  String get showUnvisitedRoadsSubtitle =>
      'Tratteggiate: le strade che restano da esplorare qui';
  @override
  String roadsUnvisitedInView(int percent) =>
      'Strade non visitate qui: $percent%';
  @override
  String get roadsUnvisitedUnknown => 'Strade non visitate qui: —';

  @override
  String get batteryOptimization => 'Ottimizzazione batteria';
  @override
  String get batteryExcluded =>
      'La registrazione è esente dal gestione batteria';
  @override
  String get batteryAdvisory =>
      'Il risparmio batteria può interrompere la registrazione — '
      'tocca per gestire';
  @override
  String salvagedRecording(String name) =>
      'Recuperata una registrazione non terminata: $name';

  @override
  String get keepScreenOn => 'Mantieni lo schermo acceso durante la registrazione';
  @override
  String get keepScreenOnSubtitle =>
      'Lo schermo resta acceso durante una sessione di registrazione';
  @override
  String get debugLogging => 'Registrazione debug';
  @override
  String get debugLoggingSubtitle =>
      'Raccogli un registro in app di posizione, registrazione e camera';
  @override
  String get saveDebugLog => 'Salva registro debug';
  @override
  String get debugLogSaved => 'Registro debug salvato (compresso gzip)';

  @override
  String get deleteAllTracks => 'Elimina tutte le tracce';
  @override
  String storedCount(int count) =>
      count == 1 ? '1 archiviata' : '$count archiviate';
  @override
  String get noStoredTracks => 'Nessuna traccia archiviata';

  @override
  String get deleteAllTracksQuestion => 'Eliminare tutte le tracce?';
  @override
  String deleteAllTracksBody(int count) =>
      'Verranno eliminate definitivamente tutte le $count tracce archiviate. '
      'I file originali da cui le hai importate non vengono toccati.';
  @override
  String get cancel => 'Annulla';
  @override
  String get close => 'Chiudi';
  @override
  String get delete => 'Elimina';
  @override
  String get allTracksDeleted => 'Tutte le tracce eliminate';

  @override
  String get selectAllTracks => 'Seleziona tutte le tracce';
  @override
  String get deselectAllTracks => 'Deseleziona tutte le tracce';
  @override
  String get nothingImportedYet => 'Ancora niente importato';
  @override
  String get deleteTrack => 'Elimina traccia';
  @override
  String deleteConfirmTitle(String trackName) => 'Eliminare "$trackName"?';
  @override
  String get deleteConfirmBody =>
      'Il file della traccia viene eliminato con essa. Operazione '
      'irreversibile.';
  @override
  String get deleteConfirmGo => 'Elimina';
  @override
  String get deleteConfirmCancel => 'Annulla';
  @override
  String pointCount(int count) => '$count punti';

  @override
  String tintName(String key) => switch (key) {
    'green' => 'Verde',
    'blue' => 'Blu',
    'orange' => 'Arancione',
    'purple' => 'Viola',
    'red' => 'Rosso',
    'teal' => 'Verde acetato',
    'amber' => 'Ambra',
    'pink' => 'Rosa',
    _ => key,
  };
}
