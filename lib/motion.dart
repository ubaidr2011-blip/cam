import 'dart:typed_data';
import 'dart:ui' as ui;

import 'camera.dart';

int _c(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// Frame-difference motion detector restricted to alarm zones.
/// It detects *movement* (people, pets, vehicles…), not "a person" specifically.
class MotionDetector {
  Uint8List? _prev;
  int _pw = 0, _ph = 0, _hits = 0;

  void reset() {
    _prev = null;
    _hits = 0;
  }

  /// True once motion inside any zone is seen on 2 consecutive checks.
  Future<bool> check(Uint8List jpeg, List<Zone> zones, double sens) async {
    final codec = await ui.instantiateImageCodec(jpeg, targetWidth: 160);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final w = img.width, h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    codec.dispose();
    if (bd == null) return false;

    final px = bd.buffer.asUint8List();
    final gray = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      gray[i] = (px[o] * 77 + px[o + 1] * 150 + px[o + 2] * 29) >> 8;
    }
    final prev = _prev;
    _prev = gray;
    if (prev == null || _pw != w || _ph != h) {
      _pw = w;
      _ph = h;
      _hits = 0;
      return false;
    }

    final thr = (45 - sens * 35).round(); // brightness change that counts: 10..45
    final minFrac = 0.06 - sens * 0.054; // share of zone pixels that must change
    var motion = false;
    for (final z in zones) {
      final x0 = _c((z.l * w).floor(), 0, w - 1);
      final x1 = _c((z.r * w).ceil(), x0 + 1, w);
      final y0 = _c((z.t * h).floor(), 0, h - 1);
      final y1 = _c((z.b * h).ceil(), y0 + 1, h);
      var changed = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = y * w + x;
          if ((gray[i] - prev[i]).abs() > thr) changed++;
        }
      }
      if (changed / ((x1 - x0) * (y1 - y0)) > minFrac) {
        motion = true;
        break;
      }
    }
    _hits = motion ? _hits + 1 : 0;
    return _hits >= 2;
  }
}
