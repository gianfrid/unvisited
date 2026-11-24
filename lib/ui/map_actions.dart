/// The map chrome widgets map_page.dart composes its overlays from: the
/// empty-state hint, the floating toolbar and its labeled actions, the
/// top toolbar and selection-bar pills, and the one shared map toast. The
/// edge clusters (control pill, record cluster) live in `map_controls.dart`.
library;

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import 'app_model.dart';
import 'track_colors.dart';

/// One shared snackbar for the map-layer chrome: hide-then-show, so a
/// rapid import never queues a slow snackbar train.
void showMapToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.route, size: 40),
            const SizedBox(height: 8),
            Text(
              strings.noTracksYet,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(strings.noTracksHint, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}

class BadgeIcon extends StatelessWidget {
  const BadgeIcon({super.key});

  @override
  Widget build(BuildContext context) => const Icon(Icons.stacked_line_chart);
}

/// The header as a compact pill that hugs its content, floating above
/// the map at the top-right corner instead of a full-width bar.
class FloatingToolbar extends StatelessWidget {
  const FloatingToolbar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A header action that says what it does: icon over a short caption.
/// Tooltips stay for long-press/hover explanations; the caption alone
/// is meant to make them unnecessary.
class HeaderAction extends StatelessWidget {
  const HeaderAction({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onTap,
    this.width = 48,
    this.iconSize = 20,
  });

  final Widget icon;
  final String label;
  final String tooltip;

  /// Null disables the action (see the Fit button on an empty map).
  final VoidCallback? onTap;

  /// Cell width; the edge clusters pass a wider one so the caption clears
  /// the pill's rounded border (the toolbar keeps the compact 48).
  final double width;

  /// Icon size; the edge clusters pass a bigger one for handlebar taps.
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final color = scheme.onSurface.withValues(alpha: enabled ? 1 : 0.38);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: width,
        height: kToolbarHeight,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme.merge(
                data: IconThemeData(size: iconSize, color: color),
                child: icon,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.0,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The top toolbar pill, centered across the map's top edge instead of a
/// full-width app bar. It is the only child of the page's top column (see
/// `MapPage`; the selection bar and the recording chip live in the bottom
/// column). While a session runs the header keeps Tracks, the session's
/// speed segment and Settings — Import and the record-mode dashboard fight
/// for space and attention (locate and record live in the edge clusters —
/// see `map_controls.dart`).
class TopToolbar extends StatelessWidget {
  const TopToolbar({
    super.key,
    required this.model,
    required this.onImport,
    required this.onOpenSettings,
  });

  final AppModel model;
  final VoidCallback onImport;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    return FloatingToolbar(
      children: [
        if (!model.isRecording)
          HeaderAction(
            icon: const Icon(Icons.add),
            label: strings.importLabel,
            tooltip: strings.importTooltip,
            onTap: onImport,
          ),
        Builder(
          builder: (context) => HeaderAction(
            icon: const BadgeIcon(),
            label: strings.tracksLabel,
            tooltip: strings.tracksLabel,
            onTap: () => Scaffold.of(context).openEndDrawer(),
          ),
        ),
        if (model.isRecording) RecordingSpeedSegment(model: model),
        HeaderAction(
          icon: const Icon(Icons.settings_outlined),
          label: strings.settingsLabel,
          tooltip: strings.settingsLabel,
          onTap: onOpenSettings,
        ),
      ],
    );
  }
}

/// The current speed as the top bar's centered segment while recording:
/// the number a rider glances at, at displaySmall over a `km/h` caption
/// in the [HeaderAction] caption style, so the pill reads as one coherent
/// bar — [Tracks] speed [Settings] — instead of a gauge bolted onto a
/// corner. It mounts with the session boundary (start and stop notify
/// the model, which rebuilds the toolbar) and repaints per fix through
/// the recording-live channel alone: the [ListenableBuilder] reads
/// `currentSpeed` inside its builder, because reading it at toolbar
/// build time would freeze the number between page rebuilds — the
/// 2026-11-19 marker lesson. A dash before the first fix and while
/// paused (paused sessions are silent), the chip's convention.
class RecordingSpeedSegment extends StatelessWidget {
  const RecordingSpeedSegment({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: kToolbarHeight,
      child: ListenableBuilder(
        listenable: model.recordingLive,
        builder: (context, _) {
          final speed = model.recording?.currentSpeed;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  speed == null
                      ? '—'
                      : (speed * 3.6).toStringAsFixed(1),
                  key: const ValueKey('recording-speed'),
                  maxLines: 1,
                  style: Theme.of(context)
                      .textTheme
                      .displaySmall
                      ?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                        color: scheme.onSurface,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'km/h',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.0,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The aggregate selection's actions pill, at the bottom of the map while
/// an aggregate is selected: hide / color / fit / tracks / dismiss. The
/// tracks button toggles member-picking mode — the selected multitrack's
/// member tracks are drawn on the map, each in its own color and lane, so
/// a map tap picks one; the picked track's actions live in the on-map
/// bubble, not here. A temporary state, the first child of the page's
/// single bottom column (see `MapPage`). [onFit] frames the selected
/// aggregate on the map (the page's camera fit); [onDismiss] clears the
/// selection in the page's state.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.model,
    required this.onFit,
    required this.onDismiss,
  });

  final AppModel model;
  final VoidCallback onFit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final model = this.model;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          key: const ValueKey('selection-bar'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const ValueKey('selection-hide'),
                  tooltip: strings.selectionHideTooltip,
                  icon: const Icon(Icons.visibility_off),
                  onPressed: () async {
                    await model.hideSelectedAggregate();
                  },
                ),
                PopupMenuButton<String>(
                  key: const ValueKey('selection-color'),
                  tooltip: strings.selectionColorTooltip,
                  icon: const Icon(Icons.palette_outlined),
                  onSelected: (key) => model.setAggregateColor(key),
                  itemBuilder: (context) => [
                    for (final entry in explorationTints.entries)
                      PopupMenuItem(
                        value: entry.key,
                        child: Row(
                          children: [
                            Icon(Icons.circle,
                                color: entry.value.withValues(alpha: 1),
                                size: 18),
                            const SizedBox(width: 8),
                            Text(
                              AppStrings.ofContext(context).tintName(entry.key),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                IconButton(
                  key: const ValueKey('selection-fit'),
                  tooltip: strings.fitTooltip,
                  icon: const Icon(Icons.zoom_out_map),
                  onPressed: () {
                    final selected = model.selectedAggregate;
                    if (selected == null || selected.points.isEmpty) return;
                    onFit();
                  },
                ),
                IconButton(
                  key: const ValueKey('selection-tracks'),
                  tooltip: strings.selectionTracksTooltip,
                  icon: const Icon(Icons.stacked_line_chart),
                  color: model.memberPicking ? scheme.primary : null,
                  onPressed: () => model.toggleMemberPicking(),
                ),
                IconButton(
                  key: const ValueKey('selection-dismiss'),
                  tooltip: strings.selectionDismissTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: onDismiss,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
