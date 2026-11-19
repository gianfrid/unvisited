import 'package:flutter/foundation.dart';

/// The playback's per-tick repaint channel. The page's replay tick
/// notifies only this Listenable — never the [AppModel] itself — so the
/// playback bar, marker and trace polyline rebuild per tick while the
/// model-wide listeners (the fog overlay, the toolbar, the whole catalog
/// tree) stay untouched. The model notifies itself only when a replay
/// starts or stops: those mount and unmount map layers and need the
/// whole page.
class PlaybackLiveState extends ChangeNotifier {
  /// Public so the page's tick can fire it — [notifyListeners] itself is
  /// protected.
  void notify() => notifyListeners();
}
