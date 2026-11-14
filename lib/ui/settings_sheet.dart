/// The settings bottom sheet: the About card, appearance controls
/// (tint, zoom-slider edge, map layer, language, theme), the road-data
/// picker and the battery advisory, plus the destructive delete-all.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../build_version.dart';
import '../l10n/app_strings.dart';
import 'app_model.dart';
import 'track_colors.dart';

/// Bottom sheet hosting all app settings: an About card (build date), the
/// map appearance controls and the destructive delete-all entry.
class SettingsSheet extends StatelessWidget {
  const SettingsSheet({
    super.key,
    required this.model,
    required this.trackCount,
    this.versionFuture,
  });

  final AppModel model;
  final int trackCount;

  /// Build time shown in the About card; tests inject a fixed value so
  /// no git process is spawned from a widget test.
  final Future<String>? versionFuture;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.settingsTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Unvisited',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(strings.aboutDescription),
                    const SizedBox(height: 8),
                    FutureBuilder<String>(
                      future: versionFuture ?? AppVersion.resolve(),
                      builder: (context, snapshot) => Text(
                        strings.buildDate(snapshot.data ?? '...'),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: Theme.of(context).hintColor),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // The appearance controls read the live model, so changes show on
            // the map behind the sheet immediately.
            AnimatedBuilder(
              animation: model,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    dense: true,
                    title: Text(strings.trackColor),
                    subtitle: Text(strings.trackColorSubtitle),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 0,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final entry in explorationTints.entries)
                          TintSwatch(
                            tintKey: entry.key,
                            color: entry.value,
                            selected: model.trackTint == entry.key,
                            onTap: () => model.setTrackTint(entry.key),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    dense: true,
                    title: Text(strings.zoomSlider),
                    subtitle: Text(strings.zoomSliderSubtitle),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 0,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'left', label: Text(strings.left)),
                        ButtonSegment(
                          value: 'right',
                          label: Text(strings.right),
                        ),
                      ],
                      selected: {model.zoomSliderSide},
                      onSelectionChanged: (selection) =>
                          model.setZoomSliderSide(selection.first),
                    ),
                  ),
                  ListTile(
                    dense: true,
                    title: Text(strings.mapLayer),
                    subtitle: Text(strings.mapLayerSubtitle),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 0,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                          value: 'standard',
                          label: Text(strings.standardLayer),
                        ),
                        ButtonSegment(
                          value: 'cycle',
                          label: Text(strings.cycleLayer),
                        ),
                      ],
                      selected: {model.tileLayer},
                      onSelectionChanged: (selection) =>
                          model.setTileLayer(selection.first),
                    ),
                  ),
                  ListTile(
                    dense: true,
                    title: Text(strings.language),
                    subtitle: Text(strings.languageSubtitle),
                    trailing: Text(
                      model.language == 'system'
                          ? strings.systemLanguage
                          : strings.languageName(model.language),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 0,
                    ),
                    onTap: () => _pickLanguage(context, model),
                  ),
                  ListTile(
                    dense: true,
                    title: Text(strings.theme),
                    subtitle: Text(strings.themeSubtitle),
                    trailing: Text(
                      model.themeMode == 'system'
                          ? strings.systemTheme
                          : model.themeMode == 'light'
                          ? strings.lightTheme
                          : strings.darkTheme,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 0,
                    ),
                    onTap: () => _pickTheme(context, model),
                  ),
                  ListTile(
                    dense: true,
                    title: Text(strings.roadData),
                    subtitle: Text(strings.roadDataSubtitle),
                    trailing: Text(
                      model.roadsName ?? strings.roadDataNone,
                      overflow: TextOverflow.ellipsis,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 0,
                    ),
                    onTap: () => _pickRoadData(context, model),
                  ),
                  // Battery optimization: Android-only, and soft — the row
                  // only reports the state and its tap opens the system
                  // page; nothing blocks, nothing is requested for the app.
                  // (Available only on Android because that is the only
                  // platform the host channel answers on.)
                  if (Platform.isAndroid)
                    FutureBuilder<bool?>(
                      future: model.batteryOptimizationExcluded(),
                      builder: (context, snapshot) => ListTile(
                        dense: true,
                        title: Text(strings.batteryOptimization),
                        subtitle: Text(
                          snapshot.data == true
                              ? strings.batteryExcluded
                              : strings.batteryAdvisory,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 0,
                        ),
                        onTap: () => model.openBatteryOptimizationSettings(),
                      ),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined),
              title: Text(strings.deleteAllTracks),
              subtitle: Text(
                trackCount == 0
                    ? strings.noStoredTracks
                    : strings.storedCount(trackCount),
              ),
              enabled: trackCount > 0,
              onTap: () => Navigator.of(context).pop('deleteAll'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Language picker: "system" plus one entry per supported language.
///
/// A dialog rather than a DropdownButton so the choice is one tap on a
/// phone, and each language is named in itself ("Italiano", "English") -
/// someone who switched by accident can always find their way back even
/// if they cannot read the current UI language.
Future<void> _pickLanguage(BuildContext context, AppModel model) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) {
      final strings = AppStrings.ofContext(context);
      return SimpleDialog(
        title: Text(strings.language),
        children: [
          RadioGroup<String>(
            groupValue: model.language,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  value: 'system',
                  title: Text(strings.systemLanguage),
                ),
                for (final locale in AppStrings.supportedLocales)
                  RadioListTile<String>(
                    value: locale.languageCode,
                    title: Text(strings.languageName(locale.languageCode)),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
  if (choice != null) await model.setLanguage(choice);
}

/// Theme picker: "system", "light", or "dark".
Future<void> _pickTheme(BuildContext context, AppModel model) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) {
      final strings = AppStrings.ofContext(context);
      return SimpleDialog(
        title: Text(strings.theme),
        children: [
          RadioGroup<String>(
            groupValue: model.themeMode,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  value: 'system',
                  title: Text(strings.systemTheme),
                ),
                RadioListTile<String>(
                  value: 'light',
                  title: Text(strings.lightTheme),
                ),
                RadioListTile<String>(
                  value: 'dark',
                  title: Text(strings.darkTheme),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
  if (choice != null) await model.setThemeMode(choice);
}

/// Road-data picker: choose a side-loaded `.unvisited-roads` region file
/// or remove the current one. "Choose" opens the system file picker; the
/// region format, like track formats, is decided by content, so no
/// extension filter. Activation (and the unlock-state recompute a swap
/// triggers) runs on the model; the usual busy flag covers the wait.
Future<void> _pickRoadData(BuildContext context, AppModel model) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) {
      final strings = AppStrings.ofContext(context);
      return SimpleDialog(
        title: Text(strings.roadData),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('choose'),
            child: Text(strings.roadDataChoose),
          ),
          if (model.roadsName != null)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('remove'),
              child: Text(strings.roadDataRemove),
            ),
        ],
      );
    },
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'remove') {
    await model.removeRoadFile();
    return;
  }
  final failure = await model.pickRoadFile();
  if (failure != null && context.mounted) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.ofContext(context).roadDataInvalid)),
    );
  }
}

/// One selectable tint swatch for the exploration overlay, labeled by
/// its tooltip; the selection ring marks the persisted tint.
class TintSwatch extends StatelessWidget {
  const TintSwatch({
    super.key,
    required this.tintKey,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String tintKey;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = AppStrings.ofContext(context).tintName(tintKey);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Tooltip(
        message: name,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: ShapeDecoration(
              shape: CircleBorder(
                side: BorderSide(
                  width: 2,
                  color: selected ? scheme.primary : Colors.transparent,
                ),
              ),
            ),
            child: Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  // The overlay tint is translucent by design; the swatch
                  // shows the solid color it is made from.
                  color: color.withValues(alpha: 1),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
