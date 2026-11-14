/// The recording dashboard's expanded stats panel: the engine's live
/// The recording dashboard's expanded stats panel: the engine's live
/// numbers as labeled rows in the card under the HUD chip.
library;

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../recording/recording_session.dart';
import 'format.dart';

class StatsPanel extends StatelessWidget {
  const StatsPanel({super.key, required this.session, required this.strings});

  final RecordingSession session;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    String kmh(double? metersPerSecond) => metersPerSecond == null
        ? '—'
        : '${(metersPerSecond * 3.6).toStringAsFixed(1)} km/h';
    final moving = session.movingTime;
    final avg = moving.inSeconds > 0
        ? session.distanceMeters / moving.inSeconds
        : null;
    final rows = <(String, String)>[
      // The live speed is the primary readout — the big one below the
      // map's top chip (see _recordingSpeed) — not a panel row.
      (strings.statAvgSpeed, kmh(avg)),
      (
        strings.statDistance,
        session.distanceMeters > 0
            ? formatDistance(session.distanceMeters)
            : '—',
      ),
      (strings.statElapsed, formatDuration(session.elapsed)),
      (strings.statMoving, formatDuration(moving)),
      if (session.currentEle != null)
        (strings.statAltitude, '${session.currentEle!.round()} m'),
    ];
    return Card(
      key: const ValueKey('stats-panel'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(value, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
