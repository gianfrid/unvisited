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
/// — no new packages. The keys float directly on the map — no panel
/// behind them, their own throw shadows carry the depth — and
/// [CassetteScrubber] is the retro replay scrubber (recessed groove,
/// capstan thumb) that rides with the style.
///
/// Every color the style paints flows through [CassetteTones] and
/// [CassetteScrubberTones] — the single place a future tweak can break
/// the measured contrast, which test/cassette_contrast_test.dart pins
/// in both of the app's themes (WCAG: captions/glyphs ≥ 4.5:1 against
/// every cap stop, borders/LED/thumb ≥ 3:1). Contrast against the map's
/// tiles is imagery-dependent and untestable in principle; the ≥ 3:1
/// border plus the throw shadow is the deterministic guarantee.
library;

import 'package:material_ui/material_ui.dart';

/// The REC indicator light on a key's cap: dark while its function is
/// idle, lit steady while engaged-but-held (a paused recording — the
/// deck-standby convention), blinking while active (recording).
enum CassetteLed { off, steady, blink }

/// The keycaps' palette, derived from one [ColorScheme]. The cap faces
/// are gradient *pairs* ([raisedTop]/[raisedBottom] top-lit while the
/// cap is up, [latchedTop]/[latchedBottom] flipped when it is sunk) so
/// the contrast tests cover every stop the face actually paints.
class CassetteTones {
  const CassetteTones({
    required this.raisedTop,
    required this.raisedBottom,
    required this.latchedTop,
    required this.latchedBottom,
    required this.border,
    required this.glyph,
    required this.led,
  });

  factory CassetteTones.of(ColorScheme scheme) => CassetteTones(
    raisedTop: scheme.surfaceContainerLow,
    raisedBottom: scheme.surfaceContainer,
    latchedTop: scheme.surfaceContainerHigh,
    latchedBottom: scheme.surfaceContainerHighest,
    // The full-strength outline, not outlineVariant: it keeps ≥ 3:1
    // against every cap stop, so the key keeps a visible boundary even
    // over tiles matching the face tone (3.5–5.9:1 measured).
    border: scheme.outline,
    glyph: scheme.onSurface,
    // The REC lamp: the scheme's error red (5.0–10.9:1 vs every stop).
    led: scheme.error,
  );

  final Color raisedTop;
  final Color raisedBottom;
  final Color latchedTop;
  final Color latchedBottom;
  final Color border;
  final Color glyph;
  final Color led;

  /// Every gradient stop a cap's face can paint, raised or latched.
  List<Color> get stops => [
    raisedTop,
    raisedBottom,
    latchedTop,
    latchedBottom,
  ];

  /// The cap's face: top-lit while raised; latched, the gradient flips
  /// so the cap reads as recessed.
  LinearGradient face(bool sunk) => sunk
      ? LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [latchedTop, latchedBottom],
        )
      : LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [raisedTop, raisedBottom],
        );
}

/// The scrubber's palette, same contract as [CassetteTones].
class CassetteScrubberTones {
  const CassetteScrubberTones({
    required this.groove,
    required this.grooveBorder,
    required this.played,
    required this.thumbFace,
    required this.thumbFaceShade,
    required this.thumbEdge,
  });

  factory CassetteScrubberTones.of(ColorScheme scheme) =>
      CassetteScrubberTones(
        // The recessed channel; its own fill is < 3:1 against the card,
        // so the channel's edge is drawn (see [grooveBorder]).
        groove: scheme.surfaceContainerHighest,
        grooveBorder: scheme.outline,
        // The played length carries the tint (5.0–7.3:1 vs the groove).
        played: scheme.primary,
        // The capstan: the scheme's ink, not a hardcoded light cap — a
        // hardcoded one measured 1.09:1 against the light card (invisible).
        // The ink reads 9.6–13.3:1 against the groove in both themes.
        thumbFace: scheme.onSurface,
        thumbFaceShade: Color.lerp(scheme.onSurface, scheme.surface, 0.3)!,
        thumbEdge: scheme.outline,
      );

  final Color groove;
  final Color grooveBorder;
  final Color played;
  final Color thumbFace;
  final Color thumbFaceShade;
  final Color thumbEdge;
}

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
    final tones = CassetteTones.of(Theme.of(context).colorScheme);
    final enabled = widget.onTap != null;
    final sunk = widget.latched || _pressed;
    final base = tones.glyph.withValues(alpha: enabled ? 1 : 0.38);
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox(
        width: widget.width,
        height: kToolbarHeight,
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged:
              enabled ? (pressed) => setState(() => _pressed = pressed) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              transform: Matrix4.translationValues(0, sunk ? 3 : 0, 0),
              decoration: BoxDecoration(
                gradient: tones.face(sunk),
                border: Border.all(color: tones.border),
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
                                ? tones.led.withValues(alpha: enabled ? 1 : 0.38)
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
                        color: tones.led,
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

/// The retro replay scrubber: the playback Slider dressed as a cassette
/// transport control — a recessed dark groove with the played length
/// tinted, and a tall capstan-style thumb the cursor rides. Behavior
/// (seeking, clamping, live feed) is the wrapped Slider's own.
class CassetteScrubber extends StatelessWidget {
  const CassetteScrubber({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final tones = CassetteScrubberTones.of(Theme.of(context).colorScheme);
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 10,
        // The recessed groove, its edge drawn (the fill alone is < 3:1
        // against the playback card).
        trackShape: _GrooveTrackShape(edge: tones.grooveBorder),
        activeTrackColor: tones.played,
        inactiveTrackColor: tones.groove,
        thumbShape: _CapstanThumbShape(
          face: tones.thumbFace,
          faceShade: tones.thumbFaceShade,
          edge: tones.thumbEdge,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      ),
      child: Slider(value: value, onChanged: onChanged),
    );
  }
}

/// The groove: the standard rounded track, plus a one-pixel outline so
/// the recessed channel keeps a visible edge against the card in both
/// themes.
class _GrooveTrackShape extends RoundedRectSliderTrackShape {
  const _GrooveTrackShape({required this.edge});

  final Color edge;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    final height = sliderTheme.trackHeight;
    if (height == null || height <= 0) return;
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = edge,
    );
  }
}

/// The scrubber's thumb: a vertical capstan — a tall rounded cap raised
/// off the groove, drawn like the keys' caps (top-lit face, one-pixel
/// throw below). Its colors come from the tones, never hardcoded: a
/// hardcoded light cap measured 1.09:1 on the light playback card.
class _CapstanThumbShape extends SliderComponentShape {
  const _CapstanThumbShape({
    required this.face,
    required this.faceShade,
    required this.edge,
  });

  final Color face;
  final Color faceShade;
  final Color edge;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(12, 22);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required Size sizeWithOverflow,
    required double textScaleFactor,
    required double value,
  }) {
    final canvas = context.canvas;
    final cap = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: 10, height: 22),
      const Radius.circular(3),
    );
    // The throw, then the cap's top-lit face, then its edge.
    canvas.drawRRect(
      cap.shift(const Offset(0, 1)),
      Paint()..color = Colors.black26,
    );
    canvas.drawRRect(
      cap,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [face, faceShade],
        ).createShader(cap.outerRect),
    );
    canvas.drawRRect(
      cap,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = edge,
    );
  }
}
