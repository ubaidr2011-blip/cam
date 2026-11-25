import 'package:flutter/foundation.dart';

import 'camera.dart';
import 'onvif.dart';
import 'session.dart';

/// Single source of truth for the camera list and their live sessions.
class AppState extends ChangeNotifier {
  final List<Camera> cams = [];
  final Map<String, Session> sessions = {};
  bool loaded = false;
  int cols = 0; // dashboard layout: 0 = auto

  Future<void> load() async {
    cams
      ..clear()
      ..addAll(await CameraStore.load());
    for (final c in cams) {
      sessions[c.id] = Session(c);
    }
    loaded = true;
    notifyListeners();
  }

  void setCols(int v) {
    cols = v;
    notifyListeners();
  }

  Session sessionOf(Camera c) => sessions[c.id]!;
  List<Session> get all => cams.map((c) => sessions[c.id]).whereType<Session>().toList();

  Future<void> save() => CameraStore.save(cams);

  Camera? sameHost(String host, {String? exceptId}) {
    for (final c in cams) {
      if (c.id != exceptId && c.host == host) return c;
    }
    return null;
  }

  Future<void> upsert(Camera cam) async {
    final i = cams.indexWhere((c) => c.id == cam.id);
    final old = sessions[cam.id];
    if (i >= 0) {
      cams[i] = cam;
    } else {
      cams.add(cam);
    }
    sessions[cam.id] = Session(cam);
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 400), () => old?.close());
    await save();
  }

  Future<void> remove(Camera cam) async {
    final old = sessions.remove(cam.id);
    cams.removeWhere((c) => c.id == cam.id);
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 400), () => old?.close());
    await save();
  }

  Future<void> removeAll() async {
    final olds = sessions.values.toList();
    sessions.clear();
    cams.clear();
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 400), () {
      for (final s in olds) {
        s.close();
      }
    });
    await save();
  }

  /// Switches every ONVIF camera to its highest-resolution stream (live + recording).
  Future<String> maximizeQuality() async {
    final out = <String>[];
    for (final cam in cams) {
      try {
        Onvif? o;
        if (cam.onvifUrl != null) {
          try {
            o = Onvif(cam.onvifUrl!, cam.user, cam.pass);
            await o.init().timeout(const Duration(seconds: 25));
          } catch (_) {
            o = null;
          }
        }
        o ??= (await Onvif.find(cam.host, cam.user, cam.pass)).onvif;
        if (o == null) {
          out.add('${cam.name}: no ONVIF – choose the main stream by editing the camera');
          continue;
        }
        final uri = await o.streamUri(sub: false);
        cam.onvifUrl = o.deviceUrl;
        cam.rtsp = uri;
        cam.liveInfo = o.lastLabel;
        cam.recRtsp = null;
        cam.recInfo = null;
        sessions[cam.id]?.start();
        out.add('${cam.name}: ${o.lastLabel ?? 'maximum'}');
      } catch (e) {
        out.add('${cam.name}: ${'$e'.replaceFirst('Exception: ', '')}');
      }
    }
    await save();
    notifyListeners();
    return out.isEmpty ? 'No cameras.' : out.join('\n');
  }

  /// Recreates every stream (used when the "Video decoding" mode changes).
  Future<void> rebuildSessions() async {
    final olds = sessions.values.toList();
    sessions.clear();
    for (final c in cams) {
      sessions[c.id] = Session(c);
    }
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 400), () {
      for (final s in olds) {
        s.close();
      }
    });
  }

  Future<void> closeAll() async {
    for (final s in sessions.values) {
      await s.close();
    }
  }
}
