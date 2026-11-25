import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings.dart';

/// Optional desktop recorder using a system-installed ffmpeg. It is the only
/// way to re-encode (H.265 / H.264, quality) – the in-app player cannot.
class FfmpegRecorder {
  static String? _path;
  static bool _checked = false;

  static bool get supported => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  static void recheck() => _checked = false;

  static String? version;

  /// Looks in the usual places (Homebrew, MacPorts, system), a path you set in
  /// Settings, and finally asks a login shell (`command -v ffmpeg`).
  static Future<String?> find() async {
    if (!supported) return null;
    if (_checked) return _path;
    _checked = true;
    _path = null;
    version = null;
    final cands = <String>[
      if (settings.ffmpegPath.trim().isNotEmpty) settings.ffmpegPath.trim(),
      '/opt/local/bin/ffmpeg', // MacPorts
      '/opt/homebrew/bin/ffmpeg', // Homebrew (Apple Silicon)
      '/usr/local/bin/ffmpeg', // Homebrew (Intel)
      '/usr/bin/ffmpeg',
    ];
    try {
      final r = await Process.run('/bin/zsh', ['-lc', 'command -v ffmpeg']);
      final s = (r.stdout as String).trim();
      if (r.exitCode == 0 && s.isNotEmpty) cands.add(s.split('\n').last.trim());
    } catch (_) {}
    for (final c in cands) {
      if (!File(c).existsSync()) continue;
      try {
        final r = await Process.run(c, ['-version']);
        if (r.exitCode == 0) {
          _path = c;
          version = (r.stdout as String).split('\n').first.trim();
          break;
        }
      } catch (_) {}
    }
    return _path;
  }

  static List<String> args(String url, String dir, String name) {
    final out = p.join(dir, '${name}_%Y-%m-%d_%H-%M-%S.mkv');
    final seg = settings.segmentMin > 0 ? settings.segmentMin * 60 : 86400;
    List<String> v;
    switch (settings.codec) {
      case 'hevc':
        final crf = {'high': '24', 'medium': '28', 'low': '32'}[settings.quality] ?? '28';
        v = ['-c:v', 'libx265', '-preset', 'veryfast', '-crf', crf];
        break;
      case 'h264':
        final crf = {'high': '20', 'medium': '24', 'low': '28'}[settings.quality] ?? '24';
        v = ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', crf];
        break;
      default:
        v = ['-c:v', 'copy'];
    }
    return [
      '-hide_banner', '-loglevel', 'warning',
      '-rtsp_transport', 'tcp', '-i', url,
      '-map', '0:v:0', '-map', '0:a:0?',
      ...v,
      '-c:a', 'aac', '-b:a', '64k',
      '-f', 'segment', '-segment_time', '$seg', '-segment_format', 'matroska',
      '-reset_timestamps', '1', '-strftime', '1',
      out,
    ];
  }
}
