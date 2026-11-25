import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'settings.dart';

class StorageOption {
  StorageOption(this.id, this.label, this.path);
  final String id, label, path;
}

/// Where recordings/snapshots live, listing, and cleanup.
class Storage {
  static String? warning; // last problem writing to the chosen folder

  static bool get isDesktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  static const videoExts = ['.mkv', '.mp4', '.ts', '.mov', '.h264'];
  static bool isVideo(File f) => videoExts.contains(p.extension(f.path).toLowerCase());

  static Future<Directory> appDir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, name)).create(recursive: true);
  }

  static Future<Directory> snapshotsDir() => appDir('Snapshots');

  static Future<List<StorageOption>> options() async {
    final out = <StorageOption>[];
    if (isDesktop) {
      final home = Platform.environment['HOME'] ?? '';
      out.add(StorageOption('default', 'Movies / LanCam', p.join(home, 'Movies', 'LanCam')));
    } else {
      final base = await getApplicationDocumentsDirectory();
      out.add(StorageOption('default', 'App storage (private)', p.join(base.path, 'Recordings')));
      try {
        final ext = await getExternalStorageDirectories(type: StorageDirectory.movies);
        if (ext != null) {
          if (ext.isNotEmpty) {
            out.add(StorageOption('external', 'Phone storage › Movies', p.join(ext[0].path, 'LanCam')));
          }
          if (ext.length > 1) {
            out.add(StorageOption('sd', 'SD card › Movies', p.join(ext[1].path, 'LanCam')));
          }
        }
      } catch (_) {}
    }
    if (settings.customPath.isNotEmpty) {
      out.add(StorageOption('custom', 'Custom folder', settings.customPath));
    }
    return out;
  }

  /// The folder recordings are written to. Falls back to app storage if not writable.
  static Future<Directory> recordingsDir() async {
    final opts = await options();
    final o = opts.firstWhere((x) => x.id == settings.folder, orElse: () => opts.first);
    try {
      final d = await Directory(o.path).create(recursive: true);
      final t = File(p.join(d.path, '.write_test'));
      await t.writeAsString('ok');
      await t.delete();
      warning = null;
      return d;
    } catch (e) {
      warning = 'Cannot write to "${o.label}" – using app storage instead.';
      return appDir('Recordings');
    }
  }

  static Future<List<Directory>> allRecordingDirs() async {
    final dirs = <String, Directory>{};
    final cur = await recordingsDir();
    dirs[cur.path] = cur;
    for (final o in await options()) {
      final d = Directory(o.path);
      if (d.existsSync()) dirs[d.path] = d;
    }
    return dirs.values.toList();
  }

  static Future<List<File>> listRecordings() async {
    final files = <File>[];
    for (final d in await allRecordingDirs()) {
      try {
        files.addAll(d.listSync().whereType<File>().where(isVideo));
      } catch (_) {}
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  static Future<int> usedBytes() async {
    var n = 0;
    for (final f in await listRecordings()) {
      try {
        n += f.lengthSync();
      } catch (_) {}
    }
    return n;
  }

  /// Applies "keep N days" and "max GB" to the current recording folder.
  static Future<void> purge() async {
    if (settings.keepDays <= 0 && settings.maxGb <= 0) return;
    try {
      final dir = await recordingsDir();
      final now = DateTime.now();
      final files = dir
          .listSync()
          .whereType<File>()
          .where(isVideo)
          .where((f) => now.difference(f.lastModifiedSync()).inMinutes > 3) // never touch files being written
          .toList()
        ..sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      if (settings.keepDays > 0) {
        for (final f in List<File>.from(files)) {
          if (now.difference(f.lastModifiedSync()).inDays >= settings.keepDays) {
            f.deleteSync();
            files.remove(f);
          }
        }
      }
      if (settings.maxGb > 0) {
        var total = files.fold<int>(0, (a, f) => a + f.lengthSync());
        final cap = (settings.maxGb * 1e9).round();
        while (total > cap && files.isNotEmpty) {
          final f = files.removeAt(0);
          total -= f.lengthSync();
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  /// macOS folder chooser (no extra plugin needed).
  static Future<String?> chooseFolder() async {
    if (!Platform.isMacOS) return null;
    final r = await Process.run('osascript',
        ['-e', 'POSIX path of (choose folder with prompt "Choose recording folder")']);
    if (r.exitCode != 0) return null;
    var s = (r.stdout as String).trim();
    if (s.length > 1 && s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s.isEmpty ? null : s;
  }
}
