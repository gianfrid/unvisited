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

  /// The record-mode dashboard's pause action; paired with [recordLabel]'s
  /// slot. Pausing closes the current `<trkseg>` (the session's existing
  /// semantics); resuming opens the next one.
  String get pauseLabel;
  String get resumeLabel;

  /// The stop-with-name dialog: the stop's title and the name field's
  /// label (the field is seeded with the current date-time timestamp).
  String get stopRecordingTitle;
  String get recordingNameLabel;

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
  String get trackColor;
  String get trackColorSubtitle;
  String get zoomSlider;
  String get zoomSliderSubtitle;

  // Base tile style (standard OSM raster or CyclOSM cycle tiles).
  String get mapLayer;
  String get mapLayerSubtitle;
  String get standardLayer;
  String get cycleLayer;

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

  // Battery optimization (Android-only, soft advisory for recording).
  String get batteryOptimization;
  String get batteryExcluded;
  String get batteryAdvisory;

  // Startup salvage: a killed session's staged recording was imported.
  String salvagedRecording(String name);

  // The recording screen latch (the chip's screen-lock toggle).
  String get screenStaysOn;
  String get screenMayTurnOff;

  String get deleteAllTracks;
  String storedCount(int count);
  String get noStoredTracks;

  // Delete-all confirmation.
  String get deleteAllTracksQuestion;
  String deleteAllTracksBody(int count);
  String get cancel;
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

  // Selection bar (aggregate tracks and selection): hide, recolor, dismiss.
  String get selectionHideTooltip;
  String get selectionColorTooltip;
  String get selectionDismissTooltip;
}

class EnglishStrings extends AppStrings {
  const EnglishStrings();

  @override
  String get importLabel => 'Import';
  @override
  String get importTooltip => 'Import tracks';
  @override
  @override
  String get fitTooltip => 'Fit tracks';
  @override
  String get selectionHideTooltip => 'Hide this area';
  @override
  String get selectionColorTooltip => 'Change the color';
  @override
  String get selectionDismissTooltip => 'Dismiss selection';
  @override
  String get locateLabel => 'Locate';
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
  String get pauseLabel => 'Pause';
  @override
  String get resumeLabel => 'Resume';
  @override
  String get stopRecordingTitle => 'Stop recording';
  @override
  String get recordingNameLabel => 'Track name';
  @override
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
  String get trackColor => 'Trace color';
  @override
  String get trackColorSubtitle =>
      'Color of the live recording trace on the map';
  @override
  String get zoomSlider => 'Zoom slider';
  @override
  String get zoomSliderSubtitle => 'Screen edge the zoom slider sits on';
  @override
  String get mapLayer => 'Map layer';
  @override
  String get mapLayerSubtitle => 'Tiles of the base map';
  @override
  String get standardLayer => 'Standard';
  @override
  String get cycleLayer => 'Cycle (CyclOSM)';
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
  String get screenStaysOn => 'Screen stays on while recording';
  @override
  String get screenMayTurnOff => 'Screen may turn off';

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
  @override
  String get fitTooltip => 'Inquadra le tracce';
  @override
  String get selectionHideTooltip => 'Nascondi quest\'area';
  @override
  String get selectionColorTooltip => 'Cambia il colore';
  @override
  String get selectionDismissTooltip => 'Annulla la selezione';
  @override
  String get locateLabel => 'Posizione';
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
  String get pauseLabel => 'Pausa';
  @override
  String get resumeLabel => 'Riprendi';
  @override
  String get stopRecordingTitle => 'Ferma la registrazione';
  @override
  String get recordingNameLabel => 'Nome della traccia';
  @override
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
  String get trackColor => 'Colore della traccia';
  @override
  String get trackColorSubtitle =>
      'Colore della traccia live in registrazione sulla mappa';
  @override
  String get zoomSlider => 'Cursore dello zoom';
  @override
  String get zoomSliderSubtitle => 'Lato dello schermo su cui si trova';
  @override
  String get mapLayer => 'Livello mappa';
  @override
  String get mapLayerSubtitle => 'Tile della mappa base';
  @override
  String get standardLayer => 'Standard';
  @override
  String get cycleLayer => 'Ciclo (CyclOSM)';
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
  String get screenStaysOn => 'Lo schermo resta acceso durante la registrazione';
  @override
  String get screenMayTurnOff => 'Lo schermo si può spegnere';

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
