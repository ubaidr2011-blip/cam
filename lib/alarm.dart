import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'alarm_data.dart';

/// Looping siren shared by all cameras. Plays while at least one alarm holds it.
class AlarmSound {
  static Player? _player;
  static final Set<String> _ids = {};

  static Future<void> acquire(String id) async {
    final wasEmpty = _ids.isEmpty;
    _ids.add(id);
    if (wasEmpty) await _play();
  }

  static Future<void> release(String id) async {
    _ids.remove(id);
    if (_ids.isEmpty) {
      try {
        await _player?.stop();
      } catch (_) {}
    }
  }

  static Future<void> _play() async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File(p.join(dir.path, 'lancam_alarm.wav'));
      if (!f.existsSync()) await f.writeAsBytes(base64Decode(alarmWavBase64));
      _player ??= Player();
      await _player!.setPlaylistMode(PlaylistMode.loop);
      await _player!.setVolume(100);
      await _player!.open(Media(f.path));
    } catch (_) {}
  }
}
