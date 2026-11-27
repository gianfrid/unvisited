/// The recording dashboard's expanded stats panel: the engine's live
/// numbers as a compact two-column grid in the card under the HUD chip.
library;

import 'package:material_ui/material_ui.dart';

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
      // The live speed is the chip's headline readout, not a panel row.
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
    // Two per row: five stats become three rows instead of five, keeping
    // the card (and the bottom column the follow-camera must clear) short.
    final grid = <TableRow>[
      for (var i = 0; i < rows.length; i += 2)
        TableRow(
          children: [
            _cell(context, rows[i]),
            if (i + 1 < rows.length)
              _cell(context, rows[i + 1])
            else
              const SizedBox.shrink(),
          ],
        ),
    ];
    return Card(
      key: const ValueKey('stats-panel'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: const {
            0: FlexColumnWidth(),
            1: FlexColumnWidth(),
          },
          children: grid,
        ),
      ),
    );
  }

  /// One stat: the label above its value, in a fixed half-width cell.
  Widget _cell(BuildContext context, (String, String) stat) {
    final (label, value) = stat;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
