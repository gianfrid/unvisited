/// The map chrome widgets map_page.dart composes overlays from: the
/// empty-state hint, the floating toolbar and its labeled actions.
library;

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

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
