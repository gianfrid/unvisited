/// The lateral zoom slider pinned to the map's configured edge: step
/// buttons at the ends, a draggable rail, the live zoom as the thumb.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../l10n/app_strings.dart';

/// OSM standard tiles exist between zoom 0 and 19; 3 is a world view that
/// still feels like a map. Both the camera and the zoom slider stay inside.
const mapMinZoom = 3.0;
const mapMaxZoom = 19.0;

/// Lateral zoom slider pinned to the map's left edge: step buttons at the
/// ends and a draggable rail whose thumb shows the live zoom level. It
/// tracks every camera change (wheel, pinch, keyboard R/F and double-tap),
/// not just its own input.
class ZoomSlider extends StatefulWidget {
  const ZoomSlider({super.key, required this.controller});

  final MapController controller;

  @override
  State<ZoomSlider> createState() => ZoomSliderState();
}

class ZoomSliderState extends State<ZoomSlider> {
  static const _trackExtent = 180.0;
  static const _thumbExtent = 28.0;

  StreamSubscription<MapEvent>? _events;
  double _zoom = mapMinZoom; // overwritten in initState from the camera

  @override
  void initState() {
    super.initState();
    _zoom = widget.controller.camera.zoom.clamp(mapMinZoom, mapMaxZoom);
    // Any camera move (pinch, wheel, fit) updates the thumb's position.
    _events = widget.controller.mapEventStream.listen((event) {
      final zoom = event.camera.zoom.clamp(mapMinZoom, mapMaxZoom);
      if (zoom != _zoom) setState(() => _zoom = zoom);
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _moveTo(double zoom) {
    final target = zoom.clamp(mapMinZoom, mapMaxZoom);
    if (target == _zoom) return;
    final camera = widget.controller.camera;
    widget.controller.move(camera.center, target);
  }

  void _dragTo(Offset localPosition) {
    // Top of the rail is max zoom; dragging up zooms in.
    final fraction = (1 - localPosition.dy / _trackExtent).clamp(0.0, 1.0);
    _moveTo(mapMinZoom + fraction * (mapMaxZoom - mapMinZoom));
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final scheme = Theme.of(context).colorScheme;
    final fraction = (_zoom - mapMinZoom) / (mapMaxZoom - mapMinZoom);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(blurRadius: 6, color: Colors.black26, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomStepButton(
            icon: Icons.add,
            tooltip: strings.zoomIn,
            onTap: () => _moveTo(_zoom + 1),
          ),
          SizedBox(
            key: const ValueKey('zoom-track'),
            width: 40,
            height: _trackExtent,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (details) => _dragTo(details.localPosition),
              onVerticalDragUpdate: (details) => _dragTo(details.localPosition),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Center(
                    child: Container(
                      width: 4,
                      height: _trackExtent - 8,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: fraction * (_trackExtent - _thumbExtent),
                    child: Container(
                      width: _thumbExtent,
                      height: _thumbExtent,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(blurRadius: 4, color: Colors.black38),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _ZoomStepButton(
            icon: Icons.remove,
            tooltip: strings.zoomOut,
            onTap: () => _moveTo(_zoom - 1),
          ),
        ],
      ),
    );
  }
}

class _ZoomStepButton extends StatelessWidget {
  const _ZoomStepButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 18),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }
}
