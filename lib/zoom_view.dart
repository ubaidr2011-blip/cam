import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'camera.dart';
import 'session.dart';
import 'widgets.dart';

/// Where the picture really is inside a box (the video is letter-boxed).
Rect videoRect(Size box, int w, int h) {
  if (w <= 0 || h <= 0) return Offset.zero & box;
  final ar = w / h, bar = box.width / box.height;
  if (ar > bar) {
    final hh = box.width / ar;
    return Rect.fromLTWH(0, (box.height - hh) / 2, box.width, hh);
  }
  final ww = box.height * ar;
  return Rect.fromLTWH((box.width - ww) / 2, 0, ww, box.height);
}

/// Draws the camera's alarm zones on top of the video.
class ZonePainter extends CustomPainter {
  ZonePainter(this.s) : super(repaint: s);
  final Session s;

  @override
  void paint(Canvas canvas, Size size) {
    if (s.cam.zones.isEmpty) return;
    final vr = videoRect(size, s.w, s.h);
    final col = s.alarmActive ? Colors.red : Colors.amber;
    final fill = Paint()..color = col.withAlpha(s.alarmActive ? 90 : 40);
    final line = Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final z in s.cam.zones) {
      final r = Rect.fromLTRB(vr.left + z.l * vr.width, vr.top + z.t * vr.height,
          vr.left + z.r * vr.width, vr.top + z.b * vr.height);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, line);
    }
  }

  @override
  bool shouldRepaint(covariant ZonePainter old) => true;
}

class _RectPainter extends CustomPainter {
  _RectPainter(this.a, this.b, this.color);
  final Offset? a, b;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p0 = a, p1 = b;
    if (p0 == null || p1 == null) return;
    final r = Rect.fromPoints(p0, p1);
    canvas.drawRect(r, Paint()..color = color.withAlpha(50));
    canvas.drawRect(
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _RectPainter old) => true;
}

/// Video with digital zoom: pinch / mouse-wheel / trackpad, +/- buttons,
/// and "drag a box to zoom into that area". Also draws/edits alarm zones.
class ZoomableVideo extends StatefulWidget {
  const ZoomableVideo({super.key, required this.session, this.editZones = false, this.onZonesChanged});
  final Session session;
  final bool editZones;
  final VoidCallback? onZonesChanged;

  @override
  State<ZoomableVideo> createState() => _ZoomableVideoState();
}

class _ZoomableVideoState extends State<ZoomableVideo> {
  final _tc = TransformationController();
  bool _areaMode = false;
  Offset? _a, _b;
  Size _vp = Size.zero;

  Session get s => widget.session;
  double get _scale => _tc.value.getMaxScaleOnAxis();
  bool get _drawing => widget.editZones || _areaMode;

  @override
  void initState() {
    super.initState();
    _tc.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _setScale(double sc) {
    if (sc <= 1.001) {
      _tc.value = Matrix4.identity();
      return;
    }
    final c = _tc.toScene(Offset(_vp.width / 2, _vp.height / 2));
    _tc.value = Matrix4(sc, 0, 0, 0, 0, sc, 0, 0, 0, 0, 1, 0, _vp.width / 2 - c.dx * sc, _vp.height / 2 - c.dy * sc, 0, 1);
  }

  void _finishDrag() {
    final a = _a, b = _b;
    _a = null;
    _b = null;
    if (a == null || b == null || (a - b).distance < 14) {
      setState(() {});
      return;
    }
    final sa = _tc.toScene(a), sb = _tc.toScene(b);
    if (widget.editZones) {
      final vr = videoRect(_vp, s.w, s.h);
      double nx(double x) => ((x - vr.left) / vr.width).clamp(0.0, 1.0).toDouble();
      double ny(double y) => ((y - vr.top) / vr.height).clamp(0.0, 1.0).toDouble();
      final z = Zone(math.min(nx(sa.dx), nx(sb.dx)), math.min(ny(sa.dy), ny(sb.dy)),
          math.max(nx(sa.dx), nx(sb.dx)), math.max(ny(sa.dy), ny(sb.dy)));
      if (z.r - z.l > 0.02 && z.b - z.t > 0.02) {
        s.cam.zones.add(z);
        s.configureDetection();
        widget.onZonesChanged?.call();
      }
    } else if (_areaMode) {
      final r = Rect.fromPoints(sa, sb);
      final sc = math.min(_vp.width / r.width, _vp.height / r.height).clamp(1.0, 12.0).toDouble();
      _tc.value = Matrix4(sc, 0, 0, 0, 0, sc, 0, 0, 0, 0, 1, 0, _vp.width / 2 - r.center.dx * sc,
          _vp.height / 2 - r.center.dy * sc, 0, 1);
      _areaMode = false;
    }
    setState(() {});
  }

  Widget _mini(IconData icon, String tip, VoidCallback f, {bool active = false}) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Material(
          color: active ? kAccent : Colors.black54,
          shape: const CircleBorder(),
          child: IconButton(
              tooltip: tip,
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              color: Colors.white,
              onPressed: f,
              icon: Icon(icon)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, bc) {
      _vp = Size(bc.maxWidth, bc.maxHeight);
      final zoomed = _scale > 1.01;
      return Stack(children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _tc,
            minScale: 1,
            maxScale: 12,
            panEnabled: !_drawing,
            scaleEnabled: !_drawing,
            child: SizedBox(
              width: _vp.width,
              height: _vp.height,
              child: Stack(fit: StackFit.expand, children: [
                Video(controller: s.video, controls: NoVideoControls),
                IgnorePointer(child: CustomPaint(painter: ZonePainter(s), size: Size.infinite)),
              ]),
            ),
          ),
        ),
        if (_drawing)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) => setState(() {
                _a = d.localPosition;
                _b = d.localPosition;
              }),
              onPanUpdate: (d) => setState(() => _b = d.localPosition),
              onPanEnd: (_) => _finishDrag(),
              child: CustomPaint(
                  painter: _RectPainter(_a, _b, widget.editZones ? Colors.amber : kAccent),
                  child: Container(
                      alignment: Alignment.topCenter,
                      padding: const EdgeInsets.only(top: 10),
                      child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                          child: Text(widget.editZones ? 'Drag to draw an alarm zone' : 'Drag a box to zoom into it',
                              style: const TextStyle(fontSize: 12))))),
            ),
          ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (zoomed)
              Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                  child: Text('×${_scale.toStringAsFixed(1)}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
            _mini(Icons.add, 'Zoom in', () => _setScale((_scale * 1.5).clamp(1.0, 12.0).toDouble())),
            _mini(Icons.remove, 'Zoom out', () => _setScale((_scale / 1.5).clamp(1.0, 12.0).toDouble())),
            _mini(Icons.crop_free, 'Zoom into an area', () => setState(() => _areaMode = !_areaMode),
                active: _areaMode),
            if (zoomed) _mini(Icons.fit_screen, 'Reset zoom', () => _setScale(1)),
          ]),
        ),
      ]);
    });
  }
}
