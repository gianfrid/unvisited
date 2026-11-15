/// The map chrome widgets map_page.dart composes its overlays from: the
/// empty-state hint, the floating toolbar and its labeled actions, the
/// top toolbar / selection bar / bottom action stack pills, and the one
/// shared map toast.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../recording/recording_session.dart';
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
  });

  final Widget icon;
  final String label;
  final String tooltip;

  /// Null disables the action (see the Fit button on an empty map).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final color = scheme.onSurface.withValues(alpha: enabled ? 1 : 0.38);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 48,
        height: kToolbarHeight,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme.merge(
                data: IconThemeData(size: 20, color: color),
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
/// column). While a session runs the
/// header keeps Tracks and Settings only — Import and the record-mode
/// dashboard fight for space and attention (locate and record live in
/// the bottom-left stack).
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

/// The aggregate selection's actions pill, at the bottom of the map while
/// an aggregate is selected: hide / color / fit / dismiss — a temporary
/// state, the first child of the page's single bottom column (see
/// `MapPage`). [onFit] frames the selected aggregate on the map (the
/// page's camera fit); [onDismiss] clears the selection in the page's
/// state.
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
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          key: const ValueKey('selection-bar'),
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
                        Icon(Icons.circle, color: entry.value, size: 18),
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
              key: const ValueKey('selection-dismiss'),
              tooltip: strings.selectionDismissTooltip,
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

/// The action stack pill: the locate button with the record slot directly
/// above it (and Stop before that once paused). It is the last child of
/// the page's bottom column (see `MapPage`), aligned to the map's
/// bottom-left corner.
///
/// The record slot only shows once a session could actually start: the
/// page passes [gpsWorking] (a real fix arrived via its silent poll or a
/// locate) — a record button on a GPS-less platform would be a dead
/// button. While a session runs the slot holds Pause; once paused it
/// reads Resume and a Stop action appears before it, asking the track's
/// name before it finalizes (discarding from the same dialog is
/// two-step, confirmed). Locate stays usable during a session — its tap
/// is the way back to the follow after panning away — so [onLocate] is
/// the page's locate attempt, which knows about the session's session
/// fix shortcut; [locating] turns the button into a spinner while an
/// attempt is in flight.
class BottomActionStack extends StatefulWidget {
  const BottomActionStack({
    super.key,
    required this.model,
    required this.locating,
    required this.gpsWorking,
    required this.onLocate,
  });

  final AppModel model;

  /// True while the page's locate attempt is in flight.
  final bool locating;

  /// True once a real position fix has arrived on this device.
  final bool gpsWorking;

  final VoidCallback onLocate;

  @override
  BottomActionStackState createState() => BottomActionStackState();
}

class BottomActionStackState extends State<BottomActionStack> {
  /// Record button: starts a session through the model and pulses the
  /// chip; a declined permission says so instead of leaving a button that
  /// silently did nothing. Alongside it, the one soft POST_NOTIFICATIONS
  /// ask fires unawaited — a refusal leaves the session mute, and the
  /// once-per-run guard keeps repeated taps from nagging.
  bool _notificationsAsked = false;

  Future<void> _startRecording() async {
    final strings = AppStrings.ofContext(context);
    if (!_notificationsAsked) {
      _notificationsAsked = true;
      unawaited(widget.model.requestPostNotifications());
    }
    final staged = await widget.model.startRecording();
    if (!mounted || staged != null) return;
    showMapToast(context, strings.recordDeclined);
  }

  /// Stop: asks what to call the track first (the dialog defaults to the
  /// current date-time timestamp). Save finalizes and imports; Discard —
  /// after a confirmation, it destroys the staged track irreversibly —
  /// ends the session importing nothing; a cancelled dialog leaves the
  /// session recording.
  Future<void> _stopRecording() async {
    final strings = AppStrings.ofContext(context);
    final defaultName = widget.model.recordingName(DateTime.now());
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: defaultName);
        return AlertDialog(
          title: Text(strings.stopRecordingTitle),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: strings.recordingNameLabel),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(strings.cancel),
            ),
            TextButton(
              key: const ValueKey('stop-discard'),
              // The empty string is the discard sentinel: it aliases the
              // name field's "cleared" value, so it never collides with a
              // name result.
              onPressed: () => Navigator.of(context).pop(''),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(strings.discardLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                controller.text.trim().isEmpty
                    ? defaultName
                    : controller.text.trim(),
              ),
              child: Text(strings.saveLabel),
            ),
          ],
        );
      },
    );
    if (!mounted || name == null) return; // Cancelled: keep recording.
    if (name.isEmpty) {
      // Discard is two-step: it destroys the session's whole track —
      // ask before doing it.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(strings.discardConfirmTitle),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const ValueKey('stop-discard-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(strings.discardLabel),
            ),
          ],
        ),
      );
      if (!context.mounted || confirmed != true) return;
      await widget.model.discardRecording();
      return;
    }
    await widget.model.stopRecording(name: name);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final model = widget.model;
    final recording = model.isRecording;
    final paused = model.recording?.state == RecordingState.paused;
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (recording)
            HeaderAction(
              icon: const Icon(Icons.stop),
              label: strings.stopLabel,
              tooltip: strings.stopLabel,
              onTap: _stopRecording,
            ),
          if (widget.gpsWorking || recording)
            HeaderAction(
              icon: Icon(
                recording
                    ? (paused ? Icons.play_arrow : Icons.pause)
                    : Icons.fiber_manual_record,
              ),
              label: recording
                  ? (paused ? strings.resumeLabel : strings.pauseLabel)
                  : strings.recordLabel,
              tooltip: recording
                  ? (paused ? strings.resumeLabel : strings.pauseLabel)
                  : strings.recordLabel,
              onTap: recording
                  ? (paused ? model.resumeRecording : model.pauseRecording)
                  : _startRecording,
            ),
          HeaderAction(
            icon: widget.locating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
            label: widget.locating ? strings.locating : strings.locateLabel,
            tooltip: strings.locateTooltip,
            onTap: widget.locating ? null : widget.onLocate,
          ),
        ],
      ),
    );
  }
}
