import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform.dart';

/// App-wide settings (recording folder, quality, limits…). Persisted.
class AppSettings extends ChangeNotifier {
  String folder = 'default'; // default | external | sd | custom
  String customPath = '';
  int segmentMin = 15; // split recordings every N minutes (0 = one file)
  String codec = 'copy'; // copy | hevc | h264   (re-encode needs ffmpeg, desktop only)
  String quality = 'medium'; // high | medium | low
  bool preferFfmpeg = true; // desktop: use ffmpeg when installed
  double maxGb = 0; // 0 = unlimited
  int keepDays = 0; // 0 = forever
  /// Video decoding: auto (hardware) | soft (software decode) | safe (software decode + render)
  String decode = kTv ? 'safe' : 'auto';
  String ffmpegPath = ''; // optional manual path to ffmpeg

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    folder = p.getString('s_folder') ?? 'default';
    customPath = p.getString('s_custom') ?? '';
    segmentMin = p.getInt('s_seg') ?? 15;
    codec = p.getString('s_codec') ?? 'copy';
    quality = p.getString('s_quality') ?? 'medium';
    preferFfmpeg = p.getBool('s_ff') ?? true;
    maxGb = p.getDouble('s_maxgb') ?? 0;
    keepDays = p.getInt('s_days') ?? 0;
    ffmpegPath = p.getString('s_ffpath') ?? '';
    decode = p.getString('s_decode2') ?? (kTv ? 'safe' : 'auto');
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('s_folder', folder);
    await p.setString('s_custom', customPath);
    await p.setInt('s_seg', segmentMin);
    await p.setString('s_codec', codec);
    await p.setString('s_quality', quality);
    await p.setBool('s_ff', preferFfmpeg);
    await p.setDouble('s_maxgb', maxGb);
    await p.setInt('s_days', keepDays);
    await p.setString('s_ffpath', ffmpegPath);
    await p.setString('s_decode2', decode);
    notifyListeners();
  }
}

final settings = AppSettings();
