import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'alarm.dart';
import 'camera.dart';
import 'motion.dart';
import 'recorder.dart';
import 'rtsp_recorder.dart';
import 'settings.dart';
import 'storage.dart';

enum SState { connecting, live, error, stopped }

/// Video output honouring the "Video decoding" setting (fixes garbled pictures
/// caused by buggy hardware decoders on some TVs / phones).
VideoController makeVideoController(Player p) => VideoController(p,
    configuration: VideoControllerConfiguration(enableHardwareAcceleration: settings.decode != 'safe'));

Future<void> applyDecoding(Player p) async {
  if (settings.decode == 'auto') return;
  try {
    await (p.platform as NativePlayer).setProperty('hwdec', 'no');
  } catch (_) {}
}

/// One camera stream: connection, recording, snapshots and intrusion alarm.
/// Shared between the dashboard tile and the full camera page.
class Session extends ChangeNotifier {
  Session(this.cam) {
    player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
    video = makeVideoController(player);
    _subs.add(player.stream.error.listen(_onError));
    _subs.add(player.stream.log.listen((l) => lastLog = '${l.prefix}: ${l.text}'.trim()));
    _subs.add(player.stream.width.listen((v) {
      w = v ?? 0;
      if (w > 0 && state != SState.stopped) _set(SState.live, '');
    }));
    _subs.add(player.stream.height.listen((v) {
      h = v ?? 0;
      _notify();
    }));
    start();
    configureDetection();
  }

  final Camera cam;
  late final Player player;
  late final VideoController video;
  final List<StreamSubscription> _subs = [];

  // --- stream state
  SState state = SState.connecting;
  String msg = '';
  String lastLog = '';
  int w = 0, h = 0;
  bool muted = true;
  bool _tcp = true, _triedUdp = false, _closed = false;
  Timer? _watchdog;

  // --- recording state
  String? recPath; // current file (mpv) or folder (ffmpeg); null = not recording
  DateTime? recStart;
  String? recError;
  String recEngine = '';
  String recStatus = '';
  int recBytes = 0;
  final List<String> recLog = [];
  bool _pausedForRec = false;
  Process? _ff;
  RtspRecorder? _rec;

  // --- alarm state
  bool alarmActive = false;
  bool silenced = false;
  final List<DateTime> events = [];
  final MotionDetector _det = MotionDetector();
  Timer? _detTimer, _alarmClear;
  bool _detBusy = false, _autoRec = false;

  bool get recording => recPath != null;
  bool get isLive => state == SState.live;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _set(SState s, String m) {
    if (_closed) return;
    state = s;
    msg = m;
    notifyListeners();
  }

  void _onError(String e) {
    if (state == SState.stopped || _closed) return;
    lastLog = 'error: $e';
    if (_tcp && !_triedUdp) {
      _triedUdp = true;
      _tcp = false;
      start(resetTransport: false); // some cameras only stream over UDP
    } else {
      _set(SState.error, e);
    }
  }

  // ------------------------------------------------------------------ stream

  Future<void> start({bool resetTransport = true}) async {
    if (_closed) return;
    if (resetTransport) {
      _tcp = true;
      _triedUdp = false;
    }
    _watchdog?.cancel();
    _set(SState.connecting, 'Connecting (${_tcp ? 'TCP' : 'UDP'})…');
    try {
      final np = player.platform as NativePlayer;
      await np.setProperty('demuxer-lavf-o', 'rtsp_transport=${_tcp ? 'tcp' : 'udp'}');
      await np.setProperty('network-timeout', '10');
      await applyDecoding(player);
      await player.setVolume(muted ? 0 : 100);
      await player.open(Media(cam.streamUrl));
    } catch (e) {
      _set(SState.error, '$e');
      return;
    }
    _watchdog = Timer(const Duration(seconds: 15), () {
      if (state == SState.connecting) {
        _set(SState.error, 'No video received. Open the camera → Info tab.');
      }
    });
  }

  /// Closes the stream (stops network traffic); the camera stays in the list.
  Future<void> stop() async {
    _watchdog?.cancel();
    await player.stop();
    w = 0;
    h = 0;
    _det.reset();
    _set(SState.stopped, 'Stream closed');
  }

  Future<void> setMuted(bool m) async {
    muted = m;
    await player.setVolume(m ? 0 : 100);
    _notify();
  }

  // --------------------------------------------------------------- recording

  String get _safeName => cam.name.replaceAll(RegExp(r'[^\w-]'), '_');
  String get _stamp =>
      DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');

  Future<void> toggleRecord() => recording ? stopRecord() : startRecord();

  /// Recording talks to the camera on its own connection, so it works whether
  /// or not the live view is open.
  Future<void> startRecord() async {
    if (recording) return;
    recError = null;
    recBytes = 0;
    recLog.clear();
    recStatus = 'Starting…';
    await Storage.purge();
    final dir = await Storage.recordingsDir();
    final ff = await FfmpegRecorder.find();
    final useFf = ff != null && (settings.codec != 'copy' || settings.preferFfmpeg);
    recStart = DateTime.now();
    if (useFf) {
      await _startFfmpeg(ff, dir);
    } else {
      _startBuiltIn(dir);
    }
    _notify();
  }

  Future<void> stopRecord() async {
    final ff = _ff;
    final rec = _rec;
    _ff = null;
    _rec = null;
    recPath = null;
    recStart = null;
    recStatus = '';
    if (rec != null) await rec.stop();
    if (_pausedForRec) {
      _pausedForRec = false;
      start(); // give the live view back
    }
    if (ff != null) {
      try {
        ff.stdin.write('q');
        await ff.stdin.flush();
        await ff.exitCode.timeout(const Duration(seconds: 6), onTimeout: () {
          ff.kill();
          return -1;
        });
      } catch (_) {
        ff.kill();
      }
    }
    _notify();
  }

  // built-in recorder (Android + Mac): original quality, video only, .ts files
  void _startBuiltIn(Directory dir) {
    recPath = dir.path;
    recEngine = 'built-in · original quality · video only';
    final r = RtspRecorder(
      url: cam.recUrl,
      dir: dir,
      name: _safeName,
      segmentMin: settings.segmentMin,
      onFile: (f) {
        recPath = f;
        _notify();
      },
      onStatus: (s) {
        recStatus = s;
        _notify();
      },
      onProgress: (b) {
        recBytes = b;
        _notify();
      },
      onLog: (l) {
        recLog.add('${DateTime.now().toIso8601String().substring(11, 19)}  $l');
        if (recLog.length > 60) recLog.removeAt(0);
      },
      onBusy: () {
        // The camera only allows one stream: pause the live view so recording can connect.
        if (!_pausedForRec && state != SState.stopped) {
          _pausedForRec = true;
          player.stop();
          w = 0;
          h = 0;
          _set(SState.stopped, 'Live view paused while recording (this camera allows only one stream)');
        }
      },
      onFatal: (m) {
        if (_rec == null) return;
        recError = m;
        recPath = null;
        recStart = null;
        recStatus = '';
        _rec = null;
        _autoRec = false;
        _notify();
      },
    );
    _rec = r;
    unawaited(r.run());
  }

  // ffmpeg (desktop only, can re-encode to H.265 / H.264)
  Future<void> _startFfmpeg(String exe, Directory dir) async {
    final proc = await Process.start(exe, FfmpegRecorder.args(cam.recUrl, dir.path, _safeName));
    _ff = proc;
    recPath = dir.path;
    recStatus = 'Recording';
    recEngine =
        'ffmpeg · ${settings.codec == 'copy' ? 'original quality' : '${settings.codec.toUpperCase()} ${settings.quality}'}';
    proc.stdout.drain();
    proc.stderr.transform(utf8.decoder).listen((s) {
      final t = s.trim();
      if (t.isNotEmpty) lastLog = 'ffmpeg: ${t.split('\n').last}';
    });
    proc.exitCode.then((code) {
      if (_ff == proc) {
        _ff = null;
        recPath = null;
        recStart = null;
        recError = 'ffmpeg stopped (code $code). $lastLog';
        _notify();
      }
    });
  }

  // --------------------------------------------------------------- snapshots

  /// Saves the current frame as a .jpg; returns its path.
  Future<String?> snapshot() async {
    if (!isLive) throw Exception('Stream is not playing');
    final bytes = await player.screenshot(format: 'image/jpeg');
    if (bytes == null) return null;
    final dir = await Storage.snapshotsDir();
    final path = p.join(dir.path, '${_safeName}_$_stamp.jpg');
    await File(path).writeAsBytes(bytes);
    return path;
  }

  // ------------------------------------------------------------------- alarm

  /// (Re)starts motion detection according to the camera's alarm settings.
  void configureDetection() {
    _detTimer?.cancel();
    _det.reset();
    if (cam.alarmOn && cam.zones.isNotEmpty && !_closed) {
      _detTimer = Timer.periodic(const Duration(seconds: 1), (_) => _detect());
    } else {
      _clearAlarm();
    }
  }

  Future<void> _detect() async {
    if (_detBusy || !isLive || _closed) return;
    _detBusy = true;
    try {
      final bytes = await player.screenshot(format: 'image/jpeg');
      if (bytes != null && await _det.check(bytes, cam.zones, cam.sens)) _onMotion();
    } catch (_) {
    } finally {
      _detBusy = false;
    }
  }

  void _onMotion() {
    if (_closed) return;
    if (!alarmActive) {
      alarmActive = true;
      silenced = false;
      events.insert(0, DateTime.now());
      if (events.length > 50) events.removeLast();
      if (cam.alarmSound) AlarmSound.acquire(cam.id);
      if (cam.recOnAlarm && !recording) {
        _autoRec = true;
        startRecord().catchError((_) {});
      }
    }
    _alarmClear?.cancel();
    _alarmClear = Timer(const Duration(seconds: 12), _clearAlarm);
    _notify();
  }

  void testAlarm() => _onMotion();

  void silence() {
    silenced = true;
    AlarmSound.release(cam.id);
    _notify();
  }

  void _clearAlarm() {
    _alarmClear?.cancel();
    if (!alarmActive) return;
    alarmActive = false;
    AlarmSound.release(cam.id);
    if (_autoRec && recording) stopRecord().catchError((_) {});
    _autoRec = false;
    _notify();
  }

  // ------------------------------------------------------------------- close

  Future<void> close() async {
    if (_closed) return;
    _detTimer?.cancel();
    _alarmClear?.cancel();
    AlarmSound.release(cam.id);
    if (recording) {
      try {
        await stopRecord();
      } catch (_) {}
    }
    _closed = true;
    _watchdog?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    await player.dispose();
  }
}
