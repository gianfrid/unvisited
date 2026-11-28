/// The cassette-deck button style (Settings → Button style → Cassette):
/// the chrome's actions draw as the transport keys of a cassette
/// recorder — beveled keycaps that sink and *latch* while their function
/// is engaged (REC down + LED blinking while recording, LED steady and
/// PAUSE down while paused, PLAY down while a replay runs). The footprint
/// each key occupies is exactly a [HeaderAction]'s (width × 56), so the
/// two styles swap without touching any layout; behavior, tooltips and
/// captions are the action's own, unchanged.
///
/// Everything is drawn with [BoxDecoration]s and one [AnimationController]
/// — no new packages. [CassetteDeck] is the face panel the keys sit in;
/// the clusters swap it in for their usual pill container when the style
/// is active.
library;

import 'package:material_ui/material_ui.dart';

/// The REC indicator light on a key's cap: dark while its function is
/// idle, lit steady while engaged-but-held (a paused recording — the
/// deck-standby convention), blinking while active (recording).
enum CassetteLed { off, steady, blink }

/// One transport key: a raised keycap (icon over caption, like
/// [HeaderAction]) that animates down while [latched] or tapped. A
/// latched key is still tappable — a deck's pause key resumes when
/// pressed again.
class CassetteKey extends StatefulWidget {
  const CassetteKey({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onTap,
    this.width = 48,
    this.iconSize = 20,
    this.latched = false,
    this.rec = false,
    this.led = CassetteLed.off,
  });

  final Widget icon;

  /// The caption under the glyph (the action's localized name).
  final String label;
  final String tooltip;

  /// Null disables the key (same contract as [HeaderAction]).
  final VoidCallback? onTap;

  /// Cell width; the edge clusters pass the wider one (56) so the
  /// caption clears the deck's rounded border.
  final double width;

  /// Glyph size; the edge clusters pass the bigger one (24) for
  /// handlebar taps.
  final double iconSize;

  /// True while the key's function is engaged: the cap stays sunk.
  final bool latched;

  /// True for the record key: its glyph wears the scheme's error red,
  /// the deck's REC marking.
  final bool rec;

  /// The REC light's mode (see [CassetteLed]).
  final CassetteLed led;

  @override
  CassetteKeyState createState() => CassetteKeyState();
}

class CassetteKeyState extends State<CassetteKey>
    with SingleTickerProviderStateMixin {
  /// The blink: a 1 s loop, on for the first half — the step blink of a
  /// deck's REC light. Only runs while the mode is [CassetteLed.blink].
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  /// The momentary press: an unlatched key sinks a notch while the
  /// finger is down, so a tap feels mechanical even when it does not
  /// latch.
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    if (widget.led == CassetteLed.blink) _blink.repeat();
  }

  @override
  void didUpdateWidget(CassetteKey oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.led == oldWidget.led) return;
    if (widget.led == CassetteLed.blink) {
      _blink.repeat();
    } else {
      _blink
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    final sunk = widget.latched || _pressed;
    final base = scheme.onSurface.withValues(alpha: enabled ? 1 : 0.38);
    // The cap's face: a top-lit gradient while raised; latched, the
    // gradient flips and the drop shadow collapses to a top edge — the
    // cap then reads as recessed into the deck.
    final face = sunk
        ? LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              scheme.surfaceContainerHigh,
              scheme.surfaceContainerHighest,
            ],
          )
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [scheme.surfaceContainerLow, scheme.surfaceContainer],
          );
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox(
        width: widget.width,
        height: kToolbarHeight,
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: enabled
              ? (pressed) => setState(() => _pressed = pressed)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              transform: Matrix4.translationValues(0, sunk ? 3 : 0, 0),
              decoration: BoxDecoration(
                gradient: face,
                border: Border.all(
                  color: sunk
                      ? scheme.outlineVariant
                      : scheme.outlineVariant.withValues(alpha: 0.7),
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: sunk
                    ? const []
                    : [
                        // The throw: the cap rides a few pixels above the
                        // deck's face while raised.
                        BoxShadow(
                          color: Colors.black26,
                          offset: Offset(0, 3),
                          blurRadius: 2,
                        ),
                      ],
              ),
              child: Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconTheme.merge(
                          data: IconThemeData(
                            size: widget.iconSize,
                            color: widget.rec
                                ? scheme.error.withValues(
                                    alpha: enabled ? 1 : 0.38,
                                  )
                                : base,
                          ),
                          child: widget.icon,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.0,
                            fontWeight: FontWeight.w600,
                            color: base,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.led != CassetteLed.off)
                    Positioned(
                      top: 5,
                      right: 5,
                      child: _RecLight(
                        controller: _blink,
                        mode: widget.led,
                        color: scheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The REC indicator dot: a dark lens while off, lit with a soft glow
/// while steady, blinking while recording (the first half of the 1 s
/// loop lit, the second dark — a step blink, no fade).
class _RecLight extends StatelessWidget {
  const _RecLight({
    required this.controller,
    required this.mode,
    required this.color,
  });

  final AnimationController controller;
  final CassetteLed mode;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (mode == CassetteLed.steady) return _dot(lit: true);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _dot(lit: controller.value < 0.5),
    );
  }

  Widget _dot({required bool lit}) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: lit ? color : color.withValues(alpha: 0.2),
      boxShadow: lit
          ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4)]
          : const [],
    ),
  );
}

/// The deck face the keys sit in: the same rounded footprint (24 radius,
/// the same padding) as the clusters' usual pill containers, so switching
/// the style moves nothing — only the surface changes.
class CassetteDeck extends StatelessWidget {
  const CassetteDeck({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.surfaceContainerHighest, scheme.surface],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
        boxShadow: const [
          BoxShadow(blurRadius: 6, color: Colors.black26, offset: Offset(0, 2)),
        ],
      ),
      child: child,
    );
  }
}
