import 'package:flutter/material.dart';

import 'app_model.dart';
import '../l10n/app_strings.dart';

/// The unvisited-roads chip at the top of the bottom overlay column: with
/// a road region active, the share of road meters in the current view
/// that no track has unlocked yet. Hidden without a region or while
/// "Show unvisited roads" is off; an em dash while the camera is below
/// the zoom floor or over a view without roads — the number is unknown
/// there, not zero.
class RoadCoverageChip extends StatelessWidget {
  const RoadCoverageChip({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    if (model.roadsName == null || !model.showUnvisitedRoads) {
      return const SizedBox.shrink();
    }
    final strings = AppStrings.ofContext(context);
    final report = model.viewportReport;
    final text = report == null
        ? strings.roadsUnvisitedUnknown
        : strings.roadsUnvisitedInView(
            (report.unvisitedRatio * 100).round(),
          );
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.alt_route, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ],
      ),
    );
  }
}
