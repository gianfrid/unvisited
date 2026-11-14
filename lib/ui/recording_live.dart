import 'package:flutter/foundation.dart';

/// The recording's per-fix repaint channel. The engine's ~1 Hz fixes notify
/// only this Listenable — never the [AppModel] itself — so the live HUD chip,
/// stats panel, marker and trace polyline rebuild per fix while the
/// model-wide listeners (the fog overlay, the toolbar, the whole catalog
/// tree) stay untouched.
class RecordingLiveState extends ChangeNotifier {
  /// Public so the model's own members can react to a fix as easily as
  /// the UI can — [notifyListeners] itself is protected.
  void notify() => notifyListeners();
}
